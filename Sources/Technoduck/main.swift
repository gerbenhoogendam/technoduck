import AppKit
import SwiftUI

/// `--screenshot out.png`: open without taking focus, draw ~120 frames (2 s), save the window and quit.
let shotPath: String? = CommandLine.arguments.firstIndex(of: "--screenshot").flatMap { i in
    i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let store = Store()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RootView().environment(store))
        window.toolbarStyle = .unified
        window.setFrameAutosaveName(shotPath == nil ? "Main" : "")
        window.center()
        window.isReleasedWhenClosed = false

        guard let shotPath else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            let view = window.contentView!.superview ?? window.contentView!
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: shotPath).deletingLastPathComponent(), withIntermediateDirectories: true)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: shotPath))
                exit(0)
            } catch { fputs("screenshot failed: \(error)\n", stderr); exit(1) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    @objc func toggleHidden(_ sender: Any?) { store.showHidden.toggle() }
    @objc func refreshAll(_ sender: Any?) { Task { await store.refreshAll() } }
    @objc func showActivity(_ sender: Any?) { store.showInspector.toggle() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleHidden(_:)) { item.state = store.showHidden ? .on : .off }
        return true
    }
}

@MainActor func mainMenu() -> NSMenu {
    let menu = NSMenu()
    let app = NSMenu()
    app.addItem(withTitle: "About Technoduck", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Hide Technoduck", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(withTitle: "Quit Technoduck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let view = NSMenu(title: "View")
    view.addItem(withTitle: "Show Hidden Files", action: #selector(AppDelegate.toggleHidden(_:)), keyEquivalent: ".").keyEquivalentModifierMask = [.command, .shift]
    view.addItem(withTitle: "Refresh", action: #selector(AppDelegate.refreshAll(_:)), keyEquivalent: "r")
    view.addItem(.separator())
    view.addItem(withTitle: "Transfers & Timeline", action: #selector(AppDelegate.showActivity(_:)), keyEquivalent: "t").keyEquivalentModifierMask = [.command, .option]
    let window = NSMenu(title: "Window")
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    for sub in [app, edit, view, window] { let item = NSMenuItem(); item.submenu = sub; menu.addItem(item) }
    return menu
}

func syncPlanSelfTest() {
    let d0 = Date(timeIntervalSince1970: 1_000_000), d1 = d0.addingTimeInterval(3600)
    func f(_ n: String, _ size: Int64, _ d: Date, dir: Bool = false) -> RemoteFile { RemoteFile(name: n, path: "/x/" + n, isDir: dir, size: size, modified: d) }
    let l = ["a": f("a", 1, d1), "b": f("b", 2, d0), "same": f("same", 5, d0), "d": f("d", 0, d0, dir: true), "d/e": f("e", 3, d0)]
    let r = ["a": f("a", 1, d0), "b": f("b", 9, d1), "same": f("same", 5, d0), "r": f("r", 4, d0)]
    precondition(makePlan(local: l, remote: r, mode: .upload).map(\.rel) == ["a", "b", "d", "d/e"])
    precondition(makePlan(local: l, remote: r, mode: .download).map(\.rel) == ["b", "r"])
    let both = makePlan(local: l, remote: r, mode: .both).map { "\($0.rel)>\($0.to.rawValue)" }
    precondition(both == ["b>local", "d>remote", "d/e>remote", "r>local"], "\(both)")
    precondition(makePlan(local: ["same": f("same", 5, d0)], remote: ["same": f("same", 5, d0)], mode: .upload, force: true).first?.overwrite == true)
    precondition(isExcluded("x.log", "a/x.log", ["*.log"]) && isExcluded("node_modules", "node_modules", ["node_modules"]))
    precondition(isExcluded("y", "cache/y", ["cache/*"]) && !isExcluded("a.txt", "a.txt", ["*.log", "cache/*"]))
    precondition(Bookmark(excludes: " .git,node_modules\n*.log ").excludeList == [".git", "node_modules", "*.log"])
    // Bookmarks saved before the sync fields existed must still load.
    let old = try! JSONDecoder().decode(Bookmark.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","nickname":"","proto":"SFTP","host":"h","port":22,"user":"","path":""}"#.utf8))
    precondition(old.host == "h" && old.autoSync == nil && old.excludeList.isEmpty)
}

/// Syncs two temp folders through LocalService, then undoes it and checks everything is back.
func syncEngineSelfTest() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("technoduck-test-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let L = root.appendingPathComponent("L").path, R = root.appendingPathComponent("R").path
    try fm.createDirectory(atPath: L + "/sub", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: R, withIntermediateDirectories: true)
    func put(_ p: String, _ s: String) throws { try s.write(toFile: p, atomically: true, encoding: .utf8) }
    func get(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }
    try put(L + "/a.txt", "new"); try put(L + "/sub/b.txt", "two"); try put(L + "/.hidden", "x"); try put(L + "/sub/skip.log", "no"); try put(R + "/a.txt", "old content")
    /// LocalService, but deleting for real so the test leaves nothing in the Trash.
    struct TestDisk: FileService {
        let disk: LocalService
        func start() async throws -> String { disk.root }
        func list(_ dir: String) async throws -> [RemoteFile] { try await disk.list(dir) }
        func download(_ remote: String, to local: URL) async throws { try await disk.download(remote, to: local) }
        func upload(_ local: URL, to remote: String) async throws { try await disk.upload(local, to: remote) }
        func delete(_ f: RemoteFile) async throws { try FileManager.default.removeItem(atPath: f.path) }
        func mkdir(_ path: String) async throws { try await disk.mkdir(path) }
    }
    let remote = TestDisk(disk: LocalService(root: R))
    let lw = try await walk(LocalService(root: L), L, hidden: false, strict: true, exclude: ["*.log"]), rw = try await walk(remote, R, hidden: false, strict: true)
    let ops = makePlan(local: lw.files, remote: rw.files, mode: .upload)
    precondition(ops.map(\.rel) == ["a.txt", "sub", "sub/b.txt"], "\(ops.map(\.rel))")
    let engine = SyncEngine(remote: remote, localRoot: L, remoteRoot: R, backups: root.appendingPathComponent("backup"))
    var applied: [Applied] = []
    for op in ops { applied.append(try await engine.apply(op)) }
    precondition(get(R + "/a.txt") == "new" && get(R + "/sub/b.txt") == "two" && get(R + "/.hidden") == nil)
    precondition(applied[0].backup != nil && applied[2].backup == nil)
    for a in applied.reversed() { try await engine.undo(a) }
    precondition(get(R + "/a.txt") == "old content" && !fm.fileExists(atPath: R + "/sub"))
}

if CommandLine.arguments.contains("--self-test") {
    let l = parseUnixListing("""
    sftp> ls -la /srv
    drwxr-xr-x    2 bob  staff     4096 Jan 01 12:00 .
    drwxr-xr-x    2 bob  staff     4096 Jan 01 12:00 my docs
    -rw-r--r--    1 bob  staff      123 Mar 05  2021 a file.txt
    lrwxrwxrwx    1 bob  staff        7 Mar 05  2021 link -> target
    """, dir: "/srv")
    precondition(l.map(\.name) == ["my docs", "a file.txt", "link"] && l[0].isDir && l[1].size == 123 && l[1].path == "/srv/a file.txt" && l[1].modified != nil)
    let b = bookmark(fromQuickConnect: "ftp://ann@example.com:2121/pub")
    precondition(b.proto == .ftp && b.user == "ann" && b.host == "example.com" && b.port == 2121 && b.path == "/pub")
    precondition(bookmark(fromQuickConnect: "example.com").proto == .sftp)
    precondition(parentPath("/a/b") == "/a" && parentPath("/a") == "/")
    precondition(l[2].isLink && !l[1].isLink)
    // The watcher behind auto-upload and editor saves must notice a new file.
    let wdir = FileManager.default.temporaryDirectory.appendingPathComponent("technoduck-watch-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: wdir, withIntermediateDirectories: true)
    var fired = false
    let watcher = FolderWatcher(wdir.path, latency: 0.2) { fired = true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    try! "x".write(to: wdir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    let deadline = Date().addingTimeInterval(5)
    while !fired && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    precondition(watcher != nil && fired, "folder watcher did not fire")
    try? FileManager.default.removeItem(at: wdir)
    syncPlanSelfTest()
    let done = DispatchSemaphore(value: 0)
    Task.detached { do { try await syncEngineSelfTest() } catch { fatalError("sync engine: \(error)") }; done.signal() }
    done.wait()
    print("self-test ok"); exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.mainMenu = mainMenu()
    app.run()
}
