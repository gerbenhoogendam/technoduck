import Foundation

/// Everything below `root`, keyed by path relative to it, read level by level.
/// Symlinks are skipped so loops and dangling links can't hurt; `strict` fails when any folder can't be read.
func walk(_ svc: FileService, _ root: String, hidden: Bool, strict: Bool, limit: Int = .max, exclude: [String] = []) async throws -> (files: [String: RemoteFile], complete: Bool) {
    // Relative paths are built from names: listed paths may differ from `root` (e.g. /tmp vs /private/tmp).
    var out: [String: RemoteFile] = [:], level = [(path: root, rel: "")]
    while !level.isEmpty {
        try Task.checkCancellation()
        var next: [(path: String, rel: String)] = []
        for (dir, list) in zip(level, await svc.listMany(level.map(\.path))) {
            guard let list else { if strict { throw ServiceError("Could not list \(dir.path)") }; continue }
            for f in list where !f.isLink && f.name != ".DS_Store" && (hidden || !f.name.hasPrefix(".")) {
                let rel = dir.rel.isEmpty ? f.name : dir.rel + "/" + f.name
                if isExcluded(f.name, rel, exclude) { continue }
                out[rel] = f
                if f.isDir { next.append((f.path, rel)) }
            }
        }
        if out.count > limit { return (out, false) }
        level = next
    }
    return (out, true)
}

/// Shell-style patterns, matched against the name or the relative path ("node_modules", "*.log", "cache/*").
func isExcluded(_ name: String, _ rel: String, _ patterns: [String]) -> Bool {
    patterns.contains { fnmatch($0, name, 0) == 0 || fnmatch($0, rel, 0) == 0 }
}

/// Decides what to copy; never deletes anything.
/// One way: copy when missing, when the size differs, or when the source is more than a minute newer.
/// Both ways: a side that misses something gets a copy; when sizes differ the newer file wins.
/// `force` copies every file (used for copying a selection).
// shortcut: both-ways ignores same-size edits so files don't ping-pong; add checksums if that matters.
func makePlan(local: [String: RemoteFile], remote: [String: RemoteFile], mode: SyncMode, force: Bool = false) -> [SyncOp] {
    var ops: [SyncOp] = []
    func copy(_ rel: String, _ s: RemoteFile, to side: Side, over d: RemoteFile?) {
        if let d, d.isDir != s.isDir { return }  // a file on one side and a folder on the other: leave both alone
        if s.isDir { if d == nil { ops.append(SyncOp(to: side, rel: rel, isDir: true, reason: "New folder")) }; return }
        guard let d else { ops.append(SyncOp(to: side, rel: rel, size: s.size, modified: s.modified, reason: "New")); return }
        let newer = (s.modified ?? .distantPast) > (d.modified ?? .distantPast).addingTimeInterval(60)
        guard force || s.size != d.size || newer else { return }
        ops.append(SyncOp(to: side, rel: rel, size: s.size, modified: s.modified, overwrite: true,
                          reason: force ? "Replace" : s.size != d.size ? "Size differs" : "Newer"))
    }
    // Sorted, so a folder always comes before what's inside it.
    for rel in Set(local.keys).union(remote.keys).sorted() {
        let l = local[rel], r = remote[rel]
        switch mode {
        case .upload: if let l { copy(rel, l, to: .b, over: r) }
        case .download: if let r { copy(rel, r, to: .a, over: l) }
        case .both:
            guard let l, let r else {
                if let l { copy(rel, l, to: .b, over: nil) }
                if let r { copy(rel, r, to: .a, over: nil) }
                continue
            }
            guard !l.isDir, !r.isDir, l.size != r.size else { continue }
            let lm = l.modified ?? .distantPast, rm = r.modified ?? .distantPast
            if lm > rm { ops.append(SyncOp(to: .b, rel: rel, size: l.size, modified: l.modified, overwrite: true, reason: "Newer here")) }
            if rm > lm { ops.append(SyncOp(to: .a, rel: rel, size: r.size, modified: r.modified, overwrite: true, reason: "Newer there")) }
        }
    }
    return ops
}

/// Applies and undoes single steps between any two locations. Every file that gets replaced is saved under `backups` first.
struct SyncEngine {
    let a: FileService, b: FileService
    let aRoot: String, bRoot: String
    /// nil skips backups (and with them undo), as for backup snapshots.
    let backups: URL?

    func service(_ s: Side) -> FileService { s == .a ? a : b }
    func path(_ s: Side, _ rel: String) -> String { joinPath(s == .a ? aRoot : bRoot, rel) }

    func apply(_ op: SyncOp) async throws -> Applied {
        let fm = FileManager.default, from: Side = op.to == .a ? .b : .a
        let dst = service(op.to), dest = path(op.to, op.rel)
        if op.isDir {
            if dst is LocalService { try fm.createDirectory(atPath: dest, withIntermediateDirectories: true) } else { try await dst.mkdir(dest) }
            return Applied(op: op)
        }
        let b = backups?.appendingPathComponent(op.to.rawValue).appendingPathComponent(op.rel)
        if let b { try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true) }
        var backup: String?
        if dst is LocalService {
            // Checked on disk, not from the plan: a case-insensitive Mac can map two server names to one file.
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dest, isDirectory: &isDir) {
                guard !isDir.boolValue else { throw ServiceError("A folder named \(op.rel) is in the way") }
                if let b { try fm.moveItem(atPath: dest, toPath: b.path); backup = b.path } else { try fm.removeItem(atPath: dest) }
            }
            do { try await transfer(service(from), path(from, op.rel), dst, dest) } catch {
                if let backup { try? fm.removeItem(atPath: dest); try? fm.moveItem(atPath: backup, toPath: dest) }
                throw error
            }
            if let m = op.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: dest) }
        } else {
            // Some FTP servers leave dotfiles out of listings, so try to save one even when the plan thinks it's new.
            if let b, op.overwrite || (op.rel as NSString).lastPathComponent.hasPrefix(".") {
                do { try await dst.download(dest, to: b); backup = b.path } catch {
                    try? fm.removeItem(at: b)
                    if op.overwrite { throw error }
                }
            }
            try await transfer(service(from), path(from, op.rel), dst, dest)
        }
        return Applied(op: op, backup: backup)
    }

    /// Copies one file between any two locations; server to server goes through a temp file.
    private func transfer(_ src: FileService, _ from: String, _ dst: FileService, _ to: String) async throws {
        if src is LocalService { return try await dst.upload(URL(fileURLWithPath: from), to: to) }
        if dst is LocalService { return try await src.download(from, to: URL(fileURLWithPath: to)) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("technoduck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await src.download(from, to: tmp)
        try await dst.upload(tmp, to: to)
    }

    func undo(_ a: Applied) async throws {
        let fm = FileManager.default, svc = service(a.op.to), dest = path(a.op.to, a.op.rel)
        let file = RemoteFile(name: (dest as NSString).lastPathComponent, path: dest, isDir: a.op.isDir, size: 0)
        if a.op.isDir {
            // Only folders that are still empty go; anything added since stays.
            guard (try? await svc.list(dest))?.isEmpty == true else { return }
            if svc is LocalService { try fm.removeItem(atPath: dest) } else { try await svc.delete(file) }
        } else if let backup = a.backup {
            if svc is LocalService {
                try? fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil)
                try fm.moveItem(atPath: backup, toPath: dest)
            } else { try await svc.upload(URL(fileURLWithPath: backup), to: dest) }
        } else if svc is LocalService {
            try fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil)
        } else {
            try await svc.delete(file)
        }
    }
}
