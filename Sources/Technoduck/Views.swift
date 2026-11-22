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
/// What a sync or a copy is going to do. Nothing changes until you click Sync (or Copy) here.
struct SyncPlanSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("syncMode") private var mode = SyncMode.upload
    let plan: SyncPlan

    private var isCopy: Bool { plan.title != nil }
    private var verb: String { isCopy ? "Copy" : "Sync" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if store.theme.label {
                    Eyebrow("Preview · nothing has changed yet")
                    Text("\(verb.uppercased()): ").font(bebas(44)) + Text(heading.uppercased()).font(bebas(44)).foregroundColor(store.theme.accent)
                } else {
                    Text("Preview · nothing has changed yet").themedFont(.caption).foregroundStyle(.secondary)
                    Text("\(verb): \(heading)").themedFont(.title3.bold())
                }
                Text("A  \(plan.a.root)\nB  \(plan.b.root)").themedFont(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                if !isCopy { options }
                HStack(spacing: 28) {
                    if plan.mode != .download { stat("arrow.right.circle.fill", store.theme.label ? store.theme.accent : .orange, "A → B", plan.files(to: .b).count, plan.bytes(to: .b)) }
                    if plan.mode != .upload { stat("arrow.left.circle.fill", store.theme.label ? store.theme.accent : .blue, "B → A", plan.files(to: .a).count, plan.bytes(to: .a)) }
                    let replaced = plan.ops.filter(\.overwrite).count
                    if replaced > 0 { count(replaced, "Replaced, backed up first", "arrow.triangle.2.circlepath", .orange) }
                    let dirs = plan.ops.filter(\.isDir).count
                    if dirs > 0 { count(dirs, "New folders", "folder.badge.plus", .green) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)  // the list below gives way, not the paths
            .padding()
            .opacity(store.planning ? 0.5 : 1)
            Divider()
            if store.planning {
                ProgressView("Comparing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if plan.ops.isEmpty {
                ContentUnavailableView("Already in Sync", systemImage: "checkmark.circle", description: Text("Nothing would be copied this way."))
            } else {
                Table(plan.ops) {
                    TableColumn("") { op in
                        Image(systemName: op.isDir ? "folder.badge.plus" : op.to == .b ? "arrow.right" : "arrow.left")
                            .foregroundStyle(store.theme.label ? store.theme.accent : op.isDir ? Color.green : op.to == .b ? Color.orange : Color.blue)
                    }
                    .width(22)
                    TableColumn("Path") { op in Text(op.rel).lineLimit(1).truncationMode(.middle) }
                    TableColumn("Why") { op in Text(op.reason).foregroundStyle(.secondary) }.width(100)
                    TableColumn("Size") { op in Text(op.isDir ? "" : fmtBytes(op.size)).monospacedDigit().foregroundStyle(.secondary) }.width(80)
                }
                .alternatingRowBackgrounds(store.theme.label ? .disabled : .automatic)
            }
            Divider()
            HStack {
                Label("You can undo this afterwards: status bar, ⌘Z or Activity.", systemImage: "arrow.uturn.backward")
                    .themedFont(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .labelButtons(store.theme.label, accent: store.theme.accent)
                Button("\(verb) \(plan.ops.count) \(plan.ops.count == 1 ? "Item" : "Items")") {
                    let p = plan; dismiss()
                    Task { await store.run(p, title: p.title ?? "Sync " + p.mode.title.components(separatedBy: "  ·  ")[0], kind: p.kind) }
                }
                .keyboardShortcut(.defaultAction).disabled(plan.ops.isEmpty || store.planning)
                .labelButtons(store.theme.label, accent: store.theme.accent, prominent: true)
            }
            .padding()
        }
        .frame(width: 700, height: store.theme.label ? 580 : 540)
        .background(store.theme.label ? store.theme.bar ?? .clear : .clear)
        .onAppear { if !isCopy { mode = plan.mode } }
    }

    private var heading: String {
        isCopy ? { let n = plan.ops.filter(\.overwrite).count; return "replaces \(n) existing \(n == 1 ? "file" : "files")" }() : plan.mode.title.components(separatedBy: "  ·  ")[0]
    }

    /// Direction, auto-upload and what gets skipped. Picking another direction compares again.
    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Direction", selection: $mode) {
                ForEach(SyncMode.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .onChange(of: mode) { if mode != plan.mode { Task { await store.sync(mode, plan.a, plan.b, dryRun: true) } } }
            if let pp = store.planPanes, let b = store.pairable(pp.0, pp.1) {
                Toggle("Keep uploading changes from this Mac to \(b.title) while Technoduck is open",
                       isOn: Binding(get: { store.autoSyncOn(pp.0, pp.1) }, set: { store.setAutoSync($0, pp.0, pp.1) }))
                    .themedFont(.callout)
            }
            let ex = store.excludes(plan.a) + store.excludes(plan.b)
            Text((ex.isEmpty ? "" : "Skipping \(ex.joined(separator: ", ")). ") + (store.showHidden ? "Hidden files included." : "Hidden files skipped (View › Show Hidden Files)."))
                .themedFont(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder private func count(_ n: Int, _ title: String, _ symbol: String, _ color: Color) -> some View {
        if store.theme.label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n)").font(bebas(30)).foregroundStyle(store.theme.accent)
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.title2).foregroundStyle(color)
                VStack(alignment: .leading) { Text(title).themedFont(.caption).foregroundStyle(.secondary); Text("\(n)").themedFont(.headline) }
            }
        }
    }

    @ViewBuilder private func stat(_ symbol: String, _ color: Color, _ title: String, _ n: Int, _ bytes: Int64) -> some View {
        if store.theme.label {   // big condensed numbers in the accent, a spaced caption below
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n) \(n == 1 ? "FILE" : "FILES") · \(fmtBytes(bytes).uppercased())").font(bebas(30)).foregroundStyle(n > 0 ? color : .secondary)
                Text(title).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            }
        } else {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading) {
                Text(title).themedFont(.caption).foregroundStyle(.secondary)
                Text("\(n) \(n == 1 ? "file" : "files") · \(fmtBytes(bytes))").themedFont(.headline).monospacedDigit()
            }
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
            if let id = store.lastUndo, store.canUndo(id), let r = store.records.first(where: { $0.id == id }) {
                Label(r.title, systemImage: "checkmark.circle").lineLimit(1).truncationMode(.middle)
                Button("Undo") { Task { await store.rollback(id) } }
                    .controlSize(.small).help("Puts back what \(r.title) changed (⌘Z)")
                    .labelButtons(store.theme.label, accent: store.theme.accent)
            }
            Spacer()
            if store.showHidden { Label("Hidden files shown", systemImage: "eye").labelStyle(.titleAndIcon) }
            if let c = store.active?.bookmark { Image(systemName: "lock.fill").opacity(c.proto == .ftp || c.proto == .webdav ? 0 : 1); Text(c.proto.rawValue) }
            if store.theme.label {   // the status diamond
                Rectangle().fill(store.theme.accent).frame(width: 7, height: 7).rotationEffect(.degrees(45))
                    .shadow(color: store.theme.accent.opacity(0.7), radius: 5).padding(.leading, 4).accessibilityHidden(true)
            }
        }
        .themedFont(.callout).foregroundStyle(.secondary)
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
                case .done: Text("Complete · \(t.started.formatted(date: .omitted, time: .shortened))").themedFont(.caption).foregroundStyle(.green)
                case .failed(let m): Text(m).themedFont(.caption).foregroundStyle(.red).lineLimit(3)
                }
                Text(t.detail).themedFont(.caption2).foregroundStyle(.tertiary).lineLimit(2)
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
                                Text(dayTitle(day.key)).themedFont(.caption.bold()).foregroundStyle(.secondary)
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
                    Text(e.title).themedFont(.callout.weight(.medium)).lineLimit(2)
                    Spacer()
                    Text(e.date.formatted(date: .omitted, time: .shortened)).themedFont(.caption).foregroundStyle(.tertiary)
                }
                if !e.detail.isEmpty { Text(e.detail).themedFont(.caption).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle) }
                if e.bytes > 0 { Text(fmtBytes(e.bytes)).themedFont(.caption).foregroundStyle(.secondary).monospacedDigit() }
                if !e.items.isEmpty {
                    DisclosureGroup("\(e.items.count) item\(e.items.count == 1 ? "" : "s")", isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(e.items.prefix(300).enumerated()), id: \.offset) { Text($0.element).lineLimit(1).truncationMode(.middle) }
                            if e.items.count > 300 { Text("… and \(e.items.count - 300) more") }
                        }
                        .themedFont(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .themedFont(.caption)
                }
                if let r = e.recordID {
                    if store.canUndo(r) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { Task { await store.rollback(r) } }.controlSize(.small).padding(.top, 2)
                    } else if store.records.contains(where: { $0.id == r }) {
                        Label("Undone", systemImage: "checkmark").themedFont(.caption).foregroundStyle(.secondary)
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
