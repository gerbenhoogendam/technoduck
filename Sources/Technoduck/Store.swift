import Foundation
import AppKit

/// One side of the dual-pane window: the local disk on the left, a server on the right.
@MainActor @Observable final class Pane {
    var service: FileService?
    var bookmark: Bookmark?
    var path = "/"
    var files: [RemoteFile] = []
    var selection = Set<RemoteFile.ID>()
    var history: [String] = []
    var busy = false
    var error: String?
    /// Folder path → whether its computed size is complete.
    var sized: [String: Bool] = [:]
    var sizing = false
    @ObservationIgnored private var sizeTask: Task<Void, Never>?

    init(service: FileService? = nil) { self.service = service }

    var selected: [RemoteFile] { files.filter { selection.contains($0.id) } }

    func open(_ dir: String, remember: Bool = true) async {
        guard let service else { return }
        busy = true
        do {
            let list = try await service.list(dir)
            if remember, dir != path { history.append(path) }
            // Listing sizes of folders (often 4096) mean nothing; the real totals are measured below.
            files = list.map { var f = $0; if f.isDir { f.size = 0 }; return f }
            path = dir; error = nil
            measure()
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    func back() async { if let p = history.popLast() { await open(p, remember: false) } }
    func refresh() async { await open(path, remember: false) }
    func close() {
        sizeTask?.cancel(); sizing = false
        service = nil; bookmark = nil; files = []; history = []; selection = []; sized = [:]; error = nil
    }

    /// Works out every subfolder's total size in the background, one folder at a time.
    private func measure() {
        sizeTask?.cancel()
        sized = [:]
        guard let service else { return }
        let dirs = files.filter { $0.isDir && !$0.isLink }.map(\.path)
        sizing = !dirs.isEmpty
        sizeTask = Task {
            for d in dirs {
                let r = await service.folderSize(d)
                if Task.isCancelled { return }
                if let i = files.firstIndex(where: { $0.path == d }) { files[i].size = r.bytes; sized[d] = r.complete }
            }
            sizing = false
        }
    }
}

@MainActor @Observable final class Store {
    enum Tab { case transfers, timeline }

    var bookmarks: [Bookmark] = [] { didSet { save(bookmarks, "bookmarks.json"); updateWatcher() } }
    var transfers: [Transfer] = []
    var log: [LogEvent] = []
    var records: [SyncRecord] = []
    var showInspector = false
    var inspectorTab = Tab.transfers
    var showHidden = UserDefaults.standard.bool(forKey: "showHidden") { didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") } }
    var message = ""
    var planning = false
    var plan: SyncPlan?

    let local = Pane(service: LocalService(root: NSHomeDirectory()))
    let remote = Pane()

    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private let dir = support.appendingPathComponent("Technoduck")
    private var backups: URL { dir.appendingPathComponent("Backups") }
    private let editDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Technoduck/Edit")

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var watchedPath: String?
    @ObservationIgnored private var autoBusy = false
    @ObservationIgnored private var autoAgain = false
    private struct Edit { let remote: String; let bookmarkID: UUID; var stamp: Date? }
    @ObservationIgnored private var edits: [String: Edit] = [:]
    @ObservationIgnored private var editWatcher: FolderWatcher?

    /// The connected bookmark as saved (with any edits made since connecting).
    var current: Bookmark? { bookmarks.first { $0.id == remote.bookmark?.id } ?? remote.bookmark }

    init() {
        let old = Self.support.appendingPathComponent("Ferry/bookmarks.json")  // where bookmarks lived before the rename
        bookmarks = load("bookmarks.json") ?? (try? JSONDecoder().decode([Bookmark].self, from: Data(contentsOf: old)))
            ?? [Bookmark(nickname: "Home Folder", proto: .local, port: 0, path: NSHomeDirectory())]
        save(bookmarks, "bookmarks.json")
        log = load("log.json") ?? []
        records = load("syncs.json") ?? []
        Task { await local.open(NSHomeDirectory(), remember: false) }
    }
    private func load<T: Decodable>(_ name: String) -> T? { try? JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(name))) }
    private func save<T: Encodable>(_ value: T, _ name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    func visible(_ files: [RemoteFile]) -> [RemoteFile] { showHidden ? files : files.filter { !$0.name.hasPrefix(".") } }

    func connect(_ b: Bookmark, password: String? = nil) async {
        let svc = makeService(b, password: password ?? Keychain.get(b))
        remote.busy = true; message = "Connecting to \(b.title)…"
        do {
            let start = try await svc.start()
            remote.close()
            remote.service = svc; remote.bookmark = b
            message = ""
            // Reopen the folder pair this server was last synced with.
            if let p = b.syncLocal, FileManager.default.fileExists(atPath: p) { await local.open(p) }
            if let p = b.syncRemote { await remote.open(p, remember: false) }
            if b.syncRemote == nil || remote.error != nil { await remote.open(start, remember: false) }
            updateWatcher()
        } catch {
            remote.busy = false
            message = "Connection failed: \(error.localizedDescription)"
        }
    }
    func disconnect() { remote.close(); message = ""; updateWatcher() }
    func refreshAll() async { await local.refresh(); await remote.refresh() }

    // MARK: Timeline

    func addLog(_ e: LogEvent) {
        log.append(e)
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
        save(log, "log.json")
    }
    func canUndo(_ id: UUID) -> Bool { records.contains { $0.id == id && !$0.rolledBack } }

    // MARK: Copy, sync, undo

    /// Copies files and folders between the panes. `root` is the folder the items sit in.
    func copy(_ items: [RemoteFile], from root: String, to side: Side) async {
        guard let rs = remote.service, let ls = local.service, !items.isEmpty else { return }
        let (src, dst) = side == .remote ? (ls, rs) : (rs, ls)
        let dest = side == .remote ? remote : local
        let ex = current?.excludeList ?? []  // applies inside folders; an item you select yourself is always copied
        message = "Preparing copy…"
        do {
            var a: [String: RemoteFile] = [:], b: [String: RemoteFile] = [:]
            for item in items {
                a[item.name] = item
                if item.isDir { for (k, v) in try await walk(src, item.path, hidden: true, strict: true, exclude: ex).files { a[item.name + "/" + k] = v } }
                guard let d = dest.files.first(where: { $0.name == item.name }) else { continue }
                b[item.name] = d
                if d.isDir { for (k, v) in try await walk(dst, d.path, hidden: true, strict: true, exclude: ex).files { b[item.name + "/" + k] = v } }
            }
            let up = side == .remote
            let ops = up ? makePlan(local: a, remote: b, mode: .upload, force: true) : makePlan(local: b, remote: a, mode: .download, force: true)
            message = ""
            await run(SyncPlan(mode: up ? .upload : .download, localRoot: up ? root : local.path, remoteRoot: up ? remote.path : root, ops: ops),
                      title: (up ? "Uploaded " : "Downloaded ") + (items.count == 1 ? items[0].name : "\(items.count) items"),
                      kind: up ? .upload : .download)
        } catch { message = "Copy failed: \(error.localizedDescription)" }
    }

    /// Files dropped from Finder onto the server pane.
    func upload(_ urls: [URL]) async {
        for (parent, group) in Dictionary(grouping: urls, by: { $0.deletingLastPathComponent().path }) {
            let items = group.map { u in
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return RemoteFile(name: u.lastPathComponent, path: u.path, isDir: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0))
            }
            await copy(items, from: parent, to: .remote)
        }
    }

    /// Compares two folders (by default the panes'); a dry run only shows the plan. `auto` runs quietly for auto-upload.
    func sync(_ mode: SyncMode, dryRun: Bool, localRoot: String? = nil, remoteRoot: String? = nil, auto: Bool = false) async {
        guard let rs = remote.service, let ls = local.service else { return }
        let lp = localRoot ?? local.path, rp = remoteRoot ?? remote.path, hidden = showHidden, ex = current?.excludeList ?? []
        if !auto, let i = bookmarks.firstIndex(where: { $0.id == remote.bookmark?.id }), bookmarks[i].syncLocal != lp || bookmarks[i].syncRemote != rp {
            bookmarks[i].syncLocal = lp; bookmarks[i].syncRemote = rp  // remember the pair for next time
        }
        planning = true; message = auto ? "" : "Comparing \(lp) with \(rp)…"
        defer { planning = false }
        do {
            async let l = walk(ls, lp, hidden: hidden, strict: true, limit: 100_000, exclude: ex)
            async let r = walk(rs, rp, hidden: hidden, strict: true, limit: 100_000, exclude: ex)
            let (lw, rw) = try await (l, r)
            guard lw.complete, rw.complete else { throw ServiceError("More than 100,000 files — pick a smaller folder.") }
            let p = SyncPlan(mode: mode, localRoot: lp, remoteRoot: rp, ops: makePlan(local: lw.files, remote: rw.files, mode: mode))
            message = ""
            if dryRun { plan = p }
            else if p.ops.isEmpty { if !auto { message = "Already in sync — nothing to copy." } }
            else { await run(p, title: (auto ? "Auto-sync " : "Sync ") + mode.title.components(separatedBy: "  ·  ")[0], kind: .sync, quiet: auto) }
        } catch { message = "Compare failed: \(error.localizedDescription)" }
    }

    func run(_ p: SyncPlan, title: String, kind: Activity = .sync, quiet: Bool = false) async {
        guard let rs = remote.service, let b = remote.bookmark else { return }
        var rec = SyncRecord(bookmarkID: b.id, title: title, localRoot: p.localRoot, remoteRoot: p.remoteRoot)
        let engine = SyncEngine(remote: rs, localRoot: p.localRoot, remoteRoot: p.remoteRoot, backups: backups.appendingPathComponent(rec.id.uuidString))
        let t = Transfer(kind: kind, name: title, detail: p.summary)
        transfers.insert(t, at: 0)
        if !quiet { showInspector = true; inspectorTab = .transfers }
        var errors: [String] = [], bytes: Int64 = 0
        for (n, op) in p.ops.enumerated() {
            do { rec.applied.append(try await engine.apply(op)); bytes += op.size } catch { errors.append("\(op.rel): \(error.localizedDescription)") }
            t.progress = Double(n + 1) / Double(p.ops.count)
        }
        if !rec.applied.isEmpty {
            records.append(rec)
            while records.count > 30 { try? FileManager.default.removeItem(at: backups.appendingPathComponent(records.removeFirst().id.uuidString)) }
            save(records, "syncs.json")
            t.recordID = rec.id
        }
        t.state = errors.isEmpty ? .done : .failed("\(errors.count) of \(p.ops.count) failed — \(errors[0])")
        addLog(LogEvent(bookmarkID: b.id, kind: kind, title: errors.isEmpty ? title : "\(title) (\(errors.count) failed)",
                        detail: "\(p.localRoot)  ⇄  \(p.remoteRoot)\n\(p.summary)", bytes: bytes,
                        recordID: rec.applied.isEmpty ? nil : rec.id,
                        items: rec.applied.map { ($0.op.to == .remote ? "↑ " : "↓ ") + $0.op.rel + ($0.op.isDir ? "/" : "") }))
        await refreshAll()
    }

    /// Puts back what a sync or copy changed: replaced files come from the backup, new files go to the Trash (local) or are deleted (server).
    func rollback(_ id: UUID) async {
        guard let rec = records.first(where: { $0.id == id }), !rec.rolledBack else { return }
        guard let rs = remote.service, remote.bookmark?.id == rec.bookmarkID else {
            message = "Connect to \(bookmarks.first { $0.id == rec.bookmarkID }?.title ?? "that server") first to undo this."; return
        }
        setRolledBack(id)  // first, so a second click can't run it twice
        let dir = backups.appendingPathComponent(rec.id.uuidString)
        let engine = SyncEngine(remote: rs, localRoot: rec.localRoot, remoteRoot: rec.remoteRoot, backups: dir)
        let t = Transfer(kind: .rollback, name: "Undo: \(rec.title)", detail: "\(rec.applied.count) changes")
        transfers.insert(t, at: 0); showInspector = true
        var errors: [String] = []
        for (n, a) in rec.applied.reversed().enumerated() {
            do { try await engine.undo(a) } catch { errors.append("\(a.op.rel): \(error.localizedDescription)") }
            t.progress = Double(n + 1) / Double(rec.applied.count)
        }
        if errors.isEmpty { try? FileManager.default.removeItem(at: dir) }
        t.state = errors.isEmpty ? .done : .failed("\(errors.count) could not be undone — \(errors[0]). Backups kept in \(dir.path)")
        addLog(LogEvent(bookmarkID: rec.bookmarkID, kind: .rollback, title: "Undid \(rec.title)",
                        detail: errors.isEmpty ? "Restored \(rec.applied.count) changes" : "\(errors.count) could not be undone; backups kept in \(dir.path)",
                        items: errors))
        await refreshAll()
    }
    private func setRolledBack(_ id: UUID) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].rolledBack = true; save(records, "syncs.json") }
    }

    // MARK: Auto-upload

    /// Turns auto-upload for the connected bookmark on or off; switching it on pairs the folders shown now.
    func setAutoSync(_ on: Bool) {
        guard let i = bookmarks.firstIndex(where: { $0.id == remote.bookmark?.id }) else { return }
        if on { bookmarks[i].syncLocal = local.path; bookmarks[i].syncRemote = remote.path }
        bookmarks[i].autoSync = on
    }

    /// Watches the paired local folder while its server is connected and auto-upload is on.
    func updateWatcher() {
        let b = current
        let want = b?.autoSync == true && remote.service != nil && b?.syncRemote != nil ? b?.syncLocal : nil
        guard want != watchedPath else { return }
        watchedPath = want
        watcher = want.flatMap { FolderWatcher($0) { [weak self] in MainActor.assumeIsolated { self?.autoUpload() } } }
    }

    private func autoUpload() {
        guard let b = current, let lp = b.syncLocal, let rp = b.syncRemote else { return }
        if autoBusy { autoAgain = true; return }  // changes during a run get their own run afterwards
        autoBusy = true
        Task {
            repeat { autoAgain = false; await sync(.upload, dryRun: false, localRoot: lp, remoteRoot: rp, auto: true) } while autoAgain
            autoBusy = false
        }
    }

    // MARK: Edit a server file in a local app

    /// Downloads to a private folder and opens it in its default app; every save is uploaded back (and can be undone).
    func edit(_ f: RemoteFile) async {
        guard let svc = remote.service, let b = remote.bookmark, !f.isDir else { return }
        let url = editDir.appendingPathComponent(UUID().uuidString).appendingPathComponent(f.name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await svc.download(f.path, to: url)
            edits[url.path] = Edit(remote: f.path, bookmarkID: b.id, stamp: modified(url.path))
            if editWatcher == nil { editWatcher = FolderWatcher(editDir.path, latency: 0.5) { [weak self] in MainActor.assumeIsolated { self?.editsChanged() } } }
            NSWorkspace.shared.open(url)
            message = "Editing \(f.name) — every save is uploaded to the server."
        } catch { message = "Could not open \(f.name): \(error.localizedDescription)" }
    }

    private func editsChanged() {
        for (path, e) in edits {
            guard let m = modified(path), m != e.stamp else { continue }
            edits[path]?.stamp = m
            let name = (path as NSString).lastPathComponent
            guard remote.bookmark?.id == e.bookmarkID else { message = "\(name) was saved, but its server isn't connected — reconnect and save again."; continue }
            let size = Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
            let p = SyncPlan(mode: .upload, localRoot: (path as NSString).deletingLastPathComponent, remoteRoot: parentPath(e.remote),
                             ops: [SyncOp(to: .remote, rel: name, size: size, overwrite: true, reason: "Edited")])
            Task { await run(p, title: "Saved \(name)", kind: .upload, quiet: true) }
        }
    }
    private func modified(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }

    // MARK: Single-pane actions

    func delete(_ items: [RemoteFile], in pane: Pane) async {
        guard let service = pane.service else { return }
        for f in items {
            do { try await service.delete(f) } catch { pane.error = "Could not delete \(f.name): \(error.localizedDescription)"; break }
            if pane === remote, let b = pane.bookmark {
                addLog(LogEvent(bookmarkID: b.id, kind: .delete, title: "Deleted \(f.name)", detail: f.path, bytes: f.isDir ? 0 : f.size))
            }
        }
        await pane.refresh()
    }

    func mkdir(_ name: String, in pane: Pane) async {
        guard let service = pane.service, !name.isEmpty else { return }
        let p = joinPath(pane.path, name)
        do {
            try await service.mkdir(p)
            if pane === remote, let b = pane.bookmark { addLog(LogEvent(bookmarkID: b.id, kind: .mkdir, title: "Created folder \(name)", detail: p)) }
            await pane.refresh()
        } catch { pane.error = error.localizedDescription }
    }
}

/// Turns "sftp://user@host:2222/path" into a bookmark for the connection sheet.
func bookmark(fromQuickConnect text: String) -> Bookmark {
    var b = Bookmark()
    let s = text.trimmingCharacters(in: .whitespaces)
    guard let u = URL(string: s.contains("://") ? s : "sftp://" + s), let host = u.host else { b.host = s; return b }
    switch u.scheme?.lowercased() {
    case "ftp": b.proto = .ftp
    case "ftps": b.proto = .ftps
    case "http", "dav", "webdav": b.proto = .webdav
    case "https", "davs", "webdavs": b.proto = .webdavs
    default: b.proto = .sftp
    }
    b.host = host; b.user = u.user ?? ""; b.port = u.port ?? b.proto.defaultPort; b.path = u.path
    return b
}
