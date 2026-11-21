import Foundation

struct ServiceError: LocalizedError { let errorDescription: String? ; init(_ m: String) { errorDescription = m } }

protocol FileService: Sendable {
    /// Connects and returns the folder to show first.
    func start() async throws -> String
    func list(_ dir: String) async throws -> [RemoteFile]
    func download(_ remote: String, to local: URL) async throws
    func upload(_ local: URL, to remote: String) async throws
    func delete(_ file: RemoteFile) async throws
    func mkdir(_ path: String) async throws
    /// Lists several folders; nil marks one that could not be listed.
    func listMany(_ dirs: [String]) async -> [[RemoteFile]?]
    /// Total bytes below `dir`; `complete` is false when counting stopped early.
    func folderSize(_ dir: String) async -> (bytes: Int64, complete: Bool)
}

extension FileService {
    func listMany(_ dirs: [String]) async -> [[RemoteFile]?] {
        await withTaskGroup(of: (Int, [RemoteFile]?).self) { g in
            var out = [[RemoteFile]?](repeating: nil, count: dirs.count), next = 0
            func add() { let i = next; next += 1; g.addTask { (i, try? await self.list(dirs[i])) } }
            while next < min(4, dirs.count) { add() }
            while let r = await g.next() {
                out[r.0] = r.1
                if next < dirs.count { add() }
            }
            return out
        }
    }
    func folderSize(_ dir: String) async -> (bytes: Int64, complete: Bool) {
        // shortcut: remote folders stop counting after 5000 entries so huge trees don't hammer the server; raise if needed.
        guard let w = try? await walk(self, dir, hidden: true, strict: false, limit: 5000) else { return (0, false) }
        return (w.files.values.reduce(0) { $0 + ($1.isDir ? 0 : $1.size) }, w.complete)
    }
}

func makeService(_ b: Bookmark, password: String) -> FileService {
    switch b.proto {
    case .local: LocalService(root: b.path.isEmpty ? NSHomeDirectory() : b.path)
    case .ftp, .ftps: FTPService(b: b, password: password)
    case .sftp: SFTPService(b: b, password: password)
    case .webdav, .webdavs: WebDAVService(b: b, password: password)
    }
}

/// Runs a command line tool off the main thread; the password only ever travels via stdin or env, never argv.
func run(_ tool: String, _ args: [String], stdin: String = "", env: [String: String] = [:]) async throws -> (out: String, err: String, status: Int32) {
    try await withCheckedThrowingContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let (i, o, e) = (Pipe(), Pipe(), Pipe())
        p.standardInput = i; p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { cont.resume(throwing: error); return }
        i.fileHandleForWriting.write(Data(stdin.utf8)); try? i.fileHandleForWriting.close()
        DispatchQueue.global().async {
            let out = o.fileHandleForReading.readDataToEndOfFile()
            let err = e.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), p.terminationStatus))
        }
    }
}

// MARK: Local disk

struct LocalService: FileService {
    let root: String
    func start() async throws -> String { root }
    func list(_ dir: String) async throws -> [RemoteFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        // Hidden files are listed too; the panes filter them.
        return try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys).map {
            let v = try $0.resourceValues(forKeys: Set(keys))
            return RemoteFile(name: $0.lastPathComponent, path: $0.path, isDir: v.isDirectory ?? false, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate, isLink: v.isSymbolicLink ?? false)
        }
    }
    func download(_ remote: String, to local: URL) async throws { try FileManager.default.copyItem(at: URL(fileURLWithPath: remote), to: local) }
    func upload(_ local: URL, to remote: String) async throws {
        // Overwrite a file like the server protocols do, but never replace a folder.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: remote, isDirectory: &isDir), !isDir.boolValue { try FileManager.default.removeItem(atPath: remote) }
        try FileManager.default.copyItem(at: local, to: URL(fileURLWithPath: remote))
    }
    func folderSize(_ dir: String) async -> (bytes: Int64, complete: Bool) {
        let home = NSHomeDirectory()
        // Other apps' containers would trigger a privacy prompt on every visit.
        let skip = [home + "/Library/Containers", home + "/Library/Group Containers"]
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: { _, _ in true })
        while let u = e?.nextObject() as? URL {
            if Task.isCancelled { return (total, false) }
            if skip.contains(u.path) { e?.skipDescendants(); continue }
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (total, true)
    }
    func delete(_ f: RemoteFile) async throws { try FileManager.default.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil) }
    func mkdir(_ path: String) async throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
}

// MARK: FTP / FTPS via the system curl

struct FTPService: FileService {
    let b: Bookmark, password: String
    func start() async throws -> String { let h = b.path.isEmpty ? "/" : b.path; _ = try await list(h); return h }
    private var config: String {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        return b.user.isEmpty ? "" : "user = \"\(esc(b.user)):\(esc(password))\"\n"
    }
    private func url(_ path: String) -> String {
        let enc = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? String($0) }
        return "ftp://\(b.host):\(b.port)/%2F" + enc.joined(separator: "/") + (path.hasSuffix("/") ? "/" : "")
    }
    private func curl(_ args: [String]) async throws -> String {
        let tls = b.proto == .ftps ? ["--ssl-reqd"] : []
        let r = try await run("/usr/bin/curl", ["-sS", "--config", "-"] + tls + args, stdin: config)
        guard r.status == 0 else { throw ServiceError(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r.out
    }
    func list(_ dir: String) async throws -> [RemoteFile] {
        let u = url(dir == "/" ? "/" : dir + "/")
        // LIST -a shows dotfiles on most servers; fall back to plain LIST where it is rejected.
        if let text = try? await curl(["-X", "LIST -a", u]) { return parseUnixListing(text, dir: dir) }
        return parseUnixListing(try await curl([u]), dir: dir)
    }
    func download(_ remote: String, to local: URL) async throws { _ = try await curl(["-o", local.path, url(remote)]) }
    func upload(_ local: URL, to remote: String) async throws { _ = try await curl(["-T", local.path, url(remote)]) }
    func delete(_ f: RemoteFile) async throws { _ = try await curl(["-o", "/dev/null", "-Q", (f.isDir ? "RMD " : "DELE ") + f.path, url("/")]) }
    func mkdir(_ path: String) async throws { _ = try await curl(["-o", "/dev/null", "-Q", "MKD " + path, url("/")]) }
}

// MARK: SFTP via the system OpenSSH sftp client

struct SFTPService: FileService {
    let b: Bookmark, password: String
    private static let askpass: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("technoduck-askpass.sh")
        try? "#!/bin/sh\nprintf '%s\\n' \"$TECHNODUCK_PW\"\n".write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }()
    private func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    private static func isError(_ line: Substring) -> Bool {
        ["Couldn't", "Can't", "denied", "not found", "No such"].contains { line.contains($0) }
    }
    private func sftpRun(_ commands: String) async throws -> (out: String, errs: [Substring], status: Int32) {
        // shortcut: new host keys are trusted on first use without asking; add a confirm dialog if that matters.
        let args = ["-P", "\(b.port)", "-o", "StrictHostKeyChecking=accept-new", "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=15",
                    b.user.isEmpty ? b.host : "\(b.user)@\(b.host)"]
        var env = ["SSH_ASKPASS_REQUIRE": "never"]
        if !password.isEmpty { env = ["SSH_ASKPASS": Self.askpass, "SSH_ASKPASS_REQUIRE": "force", "TECHNODUCK_PW": password, "DISPLAY": ":0"] }
        let r = try await run("/usr/bin/sftp", args, stdin: commands + "\nbye\n", env: env)
        let errs = r.err.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("Connected to") && !$0.hasPrefix("Warning: Permanently added") }
        return (r.out, errs, r.status)
    }
    private func sftp(_ commands: String) async throws -> String {
        let r = try await sftpRun(commands)
        if r.status != 0 || r.errs.contains(where: Self.isError) {
            throw ServiceError(r.errs.joined(separator: "\n").isEmpty ? "sftp failed" : r.errs.joined(separator: "\n"))
        }
        return r.out
    }
    /// Lists up to 50 folders per sftp session instead of one session per folder.
    func listMany(_ dirs: [String]) async -> [[RemoteFile]?] {
        var out: [[RemoteFile]?] = []
        for start in stride(from: 0, to: dirs.count, by: 50) {
            let chunk = Array(dirs[start..<min(start + 50, dirs.count)])
            // sftp echoes each piped command as "sftp> …", which splits the output per folder.
            var blocks: [String] = []
            if let r = try? await sftpRun(chunk.map { "ls -la \(q($0))" }.joined(separator: "\n")), r.status == 0, !r.errs.contains(where: Self.isError) {
                for line in r.out.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.hasPrefix("sftp> ") { blocks.append("") } else if !blocks.isEmpty { blocks[blocks.count - 1] += line + "\n" }
                }
            }
            if blocks.count >= chunk.count { out += zip(chunk, blocks).map { parseUnixListing($1, dir: $0) } }
            else { for d in chunk { out.append(try? await list(d)) } }  // an error somewhere: find out which folder
        }
        return out
    }
    func start() async throws -> String {
        if !b.path.isEmpty { _ = try await list(b.path); return b.path }
        let out = try await sftp("pwd")
        return out.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Remote working directory: ") }.map { String($0.dropFirst(26)) } ?? "/"
    }
    func list(_ dir: String) async throws -> [RemoteFile] { parseUnixListing(try await sftp("ls -la \(q(dir))"), dir: dir) }
    func download(_ remote: String, to local: URL) async throws { _ = try await sftp("get \(q(remote)) \(q(local.path))") }
    func upload(_ local: URL, to remote: String) async throws { _ = try await sftp("put \(q(local.path)) \(q(remote))") }
    func delete(_ f: RemoteFile) async throws { _ = try await sftp((f.isDir ? "rmdir " : "rm ") + q(f.path)) }
    func mkdir(_ path: String) async throws { _ = try await sftp("mkdir \(q(path))") }
}

// MARK: WebDAV via URLSession

struct WebDAVService: FileService {
    let b: Bookmark, password: String
    func start() async throws -> String { let h = b.path.isEmpty ? "/" : b.path; _ = try await list(h); return h }
    private func request(_ path: String, _ method: String) -> URLRequest {
        var c = URLComponents()
        c.scheme = b.proto == .webdavs ? "https" : "http"; c.host = b.host; c.port = b.port; c.path = path
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        if !b.user.isEmpty { r.setValue("Basic " + Data("\(b.user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        return r
    }
    private func check(_ resp: URLResponse) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ServiceError("Server answered HTTP \(code) \(HTTPURLResponse.localizedString(forStatusCode: code))") }
    }
    func list(_ dir: String) async throws -> [RemoteFile] {
        var r = request(dir.hasSuffix("/") ? dir : dir + "/", "PROPFIND")
        r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"#.utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        try check(resp)
        let self_ = (dir.hasSuffix("/") ? dir : dir + "/")
        return PropfindParser.parse(data).filter { ($0.path.hasSuffix("/") ? $0.path : $0.path + "/") != self_ }
    }
    func download(_ remote: String, to local: URL) async throws {
        let (tmp, resp) = try await URLSession.shared.download(for: request(remote, "GET"))
        try check(resp)
        try FileManager.default.moveItem(at: tmp, to: local)
    }
    func upload(_ local: URL, to remote: String) async throws { try check(try await URLSession.shared.upload(for: request(remote, "PUT"), fromFile: local).1) }
    func delete(_ f: RemoteFile) async throws { try check(try await URLSession.shared.data(for: request(f.path, "DELETE")).1) }
    func mkdir(_ path: String) async throws { try check(try await URLSession.shared.data(for: request(path, "MKCOL")).1) }
}

final class PropfindParser: NSObject, XMLParserDelegate {
    private var files: [RemoteFile] = []
    private var text = "", href = "", size: Int64 = 0, modified: Date?, isDir = false
    private let df: DateFormatter = { let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return d }()

    static func parse(_ data: Data) -> [RemoteFile] {
        let p = PropfindParser(); let x = XMLParser(data: data)
        x.shouldProcessNamespaces = true; x.delegate = p; x.parse()
        return p.files
    }
    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if el == "response" { href = ""; size = 0; modified = nil; isDir = false }
        if el == "collection" { isDir = true }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch el {
        case "href": href = URL(string: t)?.path ?? t.removingPercentEncoding ?? t
        case "getcontentlength": size = Int64(t) ?? 0
        case "getlastmodified": modified = df.date(from: t)
        case "response":
            let path = href.count > 1 && href.hasSuffix("/") ? String(href.dropLast()) : href
            files.append(RemoteFile(name: (path as NSString).lastPathComponent, path: path, isDir: isDir, size: size, modified: modified))
        default: break
        }
    }
}
