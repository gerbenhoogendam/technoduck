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
        case .upload: if let l { copy(rel, l, to: .remote, over: r) }
        case .download: if let r { copy(rel, r, to: .local, over: l) }
        case .both:
            guard let l, let r else {
                if let l { copy(rel, l, to: .remote, over: nil) }
                if let r { copy(rel, r, to: .local, over: nil) }
                continue
            }
            guard !l.isDir, !r.isDir, l.size != r.size else { continue }
            let lm = l.modified ?? .distantPast, rm = r.modified ?? .distantPast
            if lm > rm { ops.append(SyncOp(to: .remote, rel: rel, size: l.size, modified: l.modified, overwrite: true, reason: "Newer here")) }
            if rm > lm { ops.append(SyncOp(to: .local, rel: rel, size: r.size, modified: r.modified, overwrite: true, reason: "Newer there")) }
        }
    }
    return ops
}

/// Applies and undoes single sync steps. Every file that gets replaced is saved under `backups` first.
struct SyncEngine {
    let remote: FileService
    let localRoot: String, remoteRoot: String
    let backups: URL

    func path(_ side: Side, _ rel: String) -> String { joinPath(side == .local ? localRoot : remoteRoot, rel) }

    func apply(_ op: SyncOp) async throws -> Applied {
        let fm = FileManager.default, dest = path(op.to, op.rel)
        if op.isDir {
            if op.to == .local { try fm.createDirectory(atPath: dest, withIntermediateDirectories: true) } else { try await remote.mkdir(dest) }
            return Applied(op: op)
        }
        let b = backups.appendingPathComponent(op.to.rawValue).appendingPathComponent(op.rel)
        try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: String?
        if op.to == .local {
            // Checked on disk, not from the plan: a case-insensitive Mac can map two server names to one file.
            if fm.fileExists(atPath: dest) { try fm.moveItem(atPath: dest, toPath: b.path); backup = b.path }
            do { try await remote.download(path(.remote, op.rel), to: URL(fileURLWithPath: dest)) } catch {
                if let backup { try? fm.removeItem(atPath: dest); try? fm.moveItem(atPath: backup, toPath: dest) }
                throw error
            }
            if let m = op.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: dest) }
        } else {
            // Some FTP servers leave dotfiles out of listings, so try to save one even when the plan thinks it's new.
            if op.overwrite || (op.rel as NSString).lastPathComponent.hasPrefix(".") {
                do { try await remote.download(dest, to: b); backup = b.path } catch {
                    try? fm.removeItem(at: b)
                    if op.overwrite { throw error }
                }
            }
            try await remote.upload(URL(fileURLWithPath: path(.local, op.rel)), to: dest)
        }
        return Applied(op: op, backup: backup)
    }

    func undo(_ a: Applied) async throws {
        let fm = FileManager.default, dest = path(a.op.to, a.op.rel)
        if a.op.isDir {
            // Only folders that are still empty go; anything added since stays.
            if a.op.to == .local {
                if (try? fm.contentsOfDirectory(atPath: dest))?.isEmpty == true { try fm.removeItem(atPath: dest) }
            } else if (try? await remote.list(dest))?.isEmpty == true {
                try await remote.delete(RemoteFile(name: (dest as NSString).lastPathComponent, path: dest, isDir: true, size: 0))
            }
        } else if let backup = a.backup {
            if a.op.to == .local {
                try? fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil)
                try fm.moveItem(atPath: backup, toPath: dest)
            } else { try await remote.upload(URL(fileURLWithPath: backup), to: dest) }
        } else if a.op.to == .local {
            try fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil)
        } else {
            try await remote.delete(RemoteFile(name: (dest as NSString).lastPathComponent, path: dest, isDir: false, size: 0))
        }
    }
}
