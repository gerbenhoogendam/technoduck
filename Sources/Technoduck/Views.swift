import SwiftUI
import UniformTypeIdentifiers

extension Activity {
    var color: Color {
        switch self {
        case .upload: .orange
        case .download: .blue
        case .sync: .purple
        case .delete: .red
        case .mkdir: .green
        case .rollback: .gray
        }
    }
}

/// The result of a dry run: what would be copied and how much.
struct SyncPlanSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: SyncPlan

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Dry Run — \(plan.mode.title)").font(.title3.bold())
                Text("A  \(plan.a.root)\nB  \(plan.b.root)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 28) {
                    stat("arrow.right.circle.fill", .orange, "A → B", plan.files(to: .b).count, plan.bytes(to: .b))
                    stat("arrow.left.circle.fill", .blue, "B → A", plan.files(to: .a).count, plan.bytes(to: .a))
                    let dirs = plan.ops.filter(\.isDir).count
                    if dirs > 0 {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus").font(.title2).foregroundStyle(.green)
                            VStack(alignment: .leading) { Text("New folders").font(.caption).foregroundStyle(.secondary); Text("\(dirs)").font(.headline) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            Divider()
            if plan.ops.isEmpty {
                ContentUnavailableView("Already in Sync", systemImage: "checkmark.circle", description: Text("Nothing would be copied."))
            } else {
                Table(plan.ops) {
                    TableColumn("") { op in
                        Image(systemName: op.isDir ? "folder.badge.plus" : op.to == .b ? "arrow.right" : "arrow.left")
                            .foregroundStyle(op.isDir ? Color.green : op.to == .b ? Color.orange : Color.blue)
                    }
                    .width(22)
                    TableColumn("Path") { op in Text(op.rel).lineLimit(1).truncationMode(.middle) }
                    TableColumn("Why") { op in Text(op.reason).foregroundStyle(.secondary) }.width(100)
                    TableColumn("Size") { op in Text(op.isDir ? "" : fmtBytes(op.size)).monospacedDigit().foregroundStyle(.secondary) }.width(80)
                }
            }
            Divider()
            HStack {
                Text(plan.summary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sync Now") {
                    let p = plan; dismiss()
                    Task { await store.run(p, title: "Sync " + p.mode.title.components(separatedBy: "  ·  ")[0]) }
                }
                .keyboardShortcut(.defaultAction).disabled(plan.ops.isEmpty)
            }
            .padding()
        }
        .frame(width: 680, height: 480)
    }

    private func stat(_ symbol: String, _ color: Color, _ title: String, _ n: Int, _ bytes: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text("\(n) files · \(fmtBytes(bytes))").font(.headline).monospacedDigit()
            }
        }
    }
}

struct StatusBar: View {
    @Environment(Store.self) private var store
    var body: some View {
        HStack(spacing: 8) {
            if store.planning || store.panes.contains(where: \.busy) { ProgressView().controlSize(.small) }
            Text(store.message.isEmpty ? " " : store.message).lineLimit(1).truncationMode(.tail)
            Spacer()
            if store.showHidden { Label("Hidden files shown", systemImage: "eye").labelStyle(.titleAndIcon) }
            if let c = store.active?.bookmark { Image(systemName: "lock.fill").opacity(c.proto == .ftp || c.proto == .webdav ? 0 : 1); Text(c.proto.rawValue) }
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .themeBackground(store.theme.bar, .bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct InspectorView: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("View", selection: $store.inspectorTab) {
                Text("Transfers").tag(Store.Tab.transfers)
                Text("Timeline").tag(Store.Tab.timeline)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            if store.inspectorTab == .transfers { TransfersView() } else { TimelineView() }
        }
    }
}

struct TransfersView: View {
    @Environment(Store.self) private var store
    var body: some View {
        if store.transfers.isEmpty {
            ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down", description: Text("Copies and syncs appear here."))
        } else {
            List(store.transfers) { t in TransferRow(t: t) }
                .safeAreaInset(edge: .bottom) {
                    Button("Clean Up") { store.transfers.removeAll { $0.state != .running } }.padding(8)
                }
        }
    }
}

struct TransferRow: View {
    @Environment(Store.self) private var store
    let t: Transfer
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: t.kind.symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(t.kind.color, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(t.name).lineLimit(1)
                switch t.state {
                case .running: ProgressView(value: t.progress)
                case .done: Text("Complete · \(t.started.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.green)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                Text(t.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                if t.state != .running, let r = t.recordID, store.canUndo(r) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { Task { await store.rollback(r) } }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Everything that changed on one connection, newest first, grouped per day.
struct TimelineView: View {
    @Environment(Store.self) private var store
    @State private var pick: UUID?

    var body: some View {
        let id = pick ?? store.active?.bookmark?.id ?? store.panes.compactMap(\.bookmark?.id).first ?? store.bookmarks.first?.id
        let events = store.log.filter { $0.bookmarkID == id }.sorted { $0.date > $1.date }
        let days = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        VStack(spacing: 0) {
            Picker("Connection", selection: Binding(get: { id }, set: { pick = $0 })) {
                ForEach(store.bookmarks) { b in Label("\(b.title) · \(b.proto.rawValue)", systemImage: b.proto.symbol).tag(Optional(b.id)) }
            }
            .labelsHidden().padding(.horizontal, 10).padding(.bottom, 10)
            Divider()
            if events.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "clock", description: Text("Uploads, downloads, syncs and deletes on this connection appear here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(days, id: \.key) { day in
                            Section {
                                ForEach(day.value) { e in TimelineRow(e: e) }
                            } header: {
                                Text(dayTitle(day.key)).font(.caption.bold()).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }
    private func dayTitle(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "Today" : Calendar.current.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

struct TimelineRow: View {
    @Environment(Store.self) private var store
    let e: LogEvent
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Image(systemName: e.kind.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(e.kind.color, in: Circle())
                Rectangle().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(e.title).font(.callout.weight(.medium)).lineLimit(2)
                    Spacer()
                    Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                }
                if !e.detail.isEmpty { Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle) }
                if e.bytes > 0 { Text(fmtBytes(e.bytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                if !e.items.isEmpty {
                    DisclosureGroup("\(e.items.count) item\(e.items.count == 1 ? "" : "s")", isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(e.items.prefix(300).enumerated()), id: \.offset) { Text($0.element).lineLimit(1).truncationMode(.middle) }
                            if e.items.count > 300 { Text("… and \(e.items.count - 300) more") }
                        }
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                if let r = e.recordID {
                    if store.canUndo(r) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { Task { await store.rollback(r) } }.controlSize(.small).padding(.top, 2)
                    } else if store.records.contains(where: { $0.id == r }) {
                        Label("Undone", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.top, 8)
    }
}

struct BookmarkMenu: View {
    @Environment(Store.self) private var store
    let b: Bookmark
    @Binding var editing: Bookmark?
    var body: some View {
        Button("Connect") { Task { await store.connect(b) } }
        Button("Edit Bookmark…") { editing = b }
        Button("Back Up Now", systemImage: "externaldrive.badge.timemachine") { Task { await store.backUp(b) } }
        Button(b.backupFolder == nil ? "Choose Backup Folder…" : "Change Backup Folder…") { store.chooseBackupFolder(for: b) }
        Divider()
        Button("Duplicate") { var c = b; c.id = UUID(); c.nickname = b.title + " copy"; store.bookmarks.append(c) }
        Divider()
        Button("Delete Bookmark", role: .destructive) { Keychain.set(b, ""); store.bookmarks.removeAll { $0.id == b.id } }
    }
}

struct ConnectionSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var bookmark: Bookmark
    @State private var password = ""
    @State private var saveBookmark = true
    private var isExisting: Bool { store.bookmarks.contains { $0.id == bookmark.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Protocol", selection: $bookmark.proto) {
                    ForEach(Proto.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                .onChange(of: bookmark.proto) { _, p in bookmark.port = p.defaultPort }
                TextField("Nickname", text: $bookmark.nickname, prompt: Text("Optional"))
                if bookmark.proto != .local {
                    TextField("Server", text: $bookmark.host, prompt: Text("example.com"))
                    TextField("Port", value: $bookmark.port, format: .number.grouping(.never))
                    TextField("Username", text: $bookmark.user, prompt: Text("Optional"))
                    SecureField("Password", text: $password, prompt: Text(bookmark.proto == .sftp ? "Leave empty to use your SSH key" : "Optional"))
                }
                TextField("Start folder", text: $bookmark.path, prompt: Text(bookmark.proto == .local ? homeDir : "Home folder"))
                if !isExisting { Toggle("Add to Bookmarks", isOn: $saveBookmark) }
                Section("Sync") {
                    TextField("Exclude", text: Binding(get: { bookmark.excludes ?? "" }, set: { bookmark.excludes = $0.isEmpty ? nil : $0 }),
                              prompt: Text("node_modules, .git, *.log"))
                    LabeledContent("Local folder") {
                        HStack {
                            Text(bookmark.syncLocal ?? "Not paired yet").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") {
                                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                                if p.runModal() == .OK, let u = p.url { bookmark.syncLocal = u.path }
                            }
                        }
                    }
                    TextField("Server folder", text: Binding(get: { bookmark.syncRemote ?? "" }, set: { bookmark.syncRemote = $0.isEmpty ? nil : $0 }),
                              prompt: Text("Set by your first sync"))
                    Toggle("Auto-upload changes from the local folder", isOn: Binding(get: { bookmark.autoSync ?? false }, set: { bookmark.autoSync = $0 }))
                        .disabled(bookmark.syncLocal == nil || bookmark.syncRemote == nil)
                }
                Section("Backup") {
                    LabeledContent("Backup folder") {
                        HStack {
                            Text(bookmark.backupFolder ?? "Asked on first backup").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") {
                                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                                if p.runModal() == .OK, let u = p.url { bookmark.backupFolder = u.path }
                            }
                        }
                    }
                }
                LabeledContent("URL") { Text(bookmark.url).textSelection(.enabled).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if isExisting { Button("Save") { persist(); dismiss() } }
                Button("Connect") {
                    persist()
                    let b = bookmark, pw = password
                    dismiss()
                    Task { await store.connect(b, password: pw) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bookmark.proto != .local && bookmark.host.isEmpty)
            }
            .padding()
        }
        .frame(width: 440)
        .onAppear { if isExisting { password = Keychain.get(bookmark) } }
    }

    private func persist() {
        if let i = store.bookmarks.firstIndex(where: { $0.id == bookmark.id }) { store.bookmarks[i] = bookmark }
        else if saveBookmark { store.bookmarks.append(bookmark) }
        else { return }
        Keychain.set(bookmark, password)
    }
}
