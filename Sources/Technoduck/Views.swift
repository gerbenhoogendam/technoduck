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

struct RootView: View {
    @Environment(Store.self) private var store
    @State private var editing: Bookmark?
    @State private var quick = ""

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar(editing: $editing)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            HStack(spacing: 0) {
                PaneView(pane: store.local, side: .local)
                Divider()
                CenterStrip()
                Divider()
                if store.remote.service != nil {
                    PaneView(pane: store.remote, side: .remote)
                } else {
                    BookmarksView(editing: $editing).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .inspector(isPresented: $store.showInspector) {
            InspectorView().inspectorColumnWidth(min: 280, ideal: 330)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { editing = Bookmark() } label: { Label("Open Connection", systemImage: "plus.circle") }
                    .help("Open a new connection")
            }
            ToolbarItem(placement: .principal) {
                TextField("Quick Connect — sftp://user@server", text: $quick)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 220, idealWidth: 320)
                    .onSubmit { if !quick.isEmpty { editing = bookmark(fromQuickConnect: quick); quick = "" } }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if store.remote.service != nil {
                    Button { store.disconnect() } label: { Label("Disconnect", systemImage: "eject") }.help("Disconnect")
                }
                Button { store.showInspector.toggle() } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .help("Transfers and timeline")
            }
        }
        .sheet(item: $editing) { b in ConnectionSheet(bookmark: b) }
        .sheet(item: $store.plan) { p in SyncPlanSheet(plan: p) }
        .navigationTitle("Technoduck")
        .navigationSubtitle(store.remote.bookmark?.title ?? "Not connected")
    }
}

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Binding var editing: Bookmark?

    var body: some View {
        List {
            Section("Bookmarks") {
                ForEach(store.bookmarks) { b in
                    Button { Task { await store.connect(b) } } label: {
                        Label { Text(b.title).lineLimit(1) } icon: { Image(systemName: b.proto.symbol) }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(store.remote.bookmark?.id == b.id ? .semibold : .regular)
                    .contextMenu { BookmarkMenu(b: b, editing: $editing) }
                }
            }
            if let c = store.remote.bookmark {
                Section("Connected") {
                    Label(c.url, systemImage: "bolt.horizontal.circle.fill").foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                    Button("Disconnect", systemImage: "eject") { store.disconnect() }.buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// A file list with its own path bar. The local pane is side A, the server pane side B.
struct PaneView: View {
    @Environment(Store.self) private var store
    @Bindable var pane: Pane
    let side: Side
    @State private var sort = [KeyPathComparator(\RemoteFile.name)]
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var confirmDelete = false

    private var rows: [RemoteFile] { store.visible(pane.files).sorted(using: sort).sorted { $0.isDir && !$1.isDir } }
    private var connected: Bool { store.remote.service != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { let n = folderName; folderName = ""; Task { await store.mkdir(n, in: pane) } }
            Button("Cancel", role: .cancel) { folderName = "" }
        }
        .confirmationDialog(side == .local ? "Move \(pane.selected.count) item(s) to the Trash?" : "Delete \(pane.selected.count) item(s)? This cannot be undone on the server.",
                            isPresented: $confirmDelete) {
            Button(side == .local ? "Move to Trash" : "Delete", role: .destructive) {
                let items = pane.selected; pane.selection = []
                Task { await store.delete(items, in: pane) }
            }
        }
        .onChange(of: pane.path) { pane.selection = [] }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(side == .local ? "A" : "B").font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(side == .local ? Color.orange : Color.blue, in: RoundedRectangle(cornerRadius: 4))
            Button { Task { await pane.back() } } label: { Image(systemName: "chevron.left") }.disabled(pane.history.isEmpty).help("Back")
            Button { Task { await pane.open(parentPath(pane.path)) } } label: { Image(systemName: "chevron.up") }.disabled(pane.path == "/").help("Enclosing folder")
            Menu {
                ForEach(ancestors, id: \.self) { p in Button(p) { Task { await pane.open(p) } } }
                if side == .local { Divider(); Button("Choose Folder…") { chooseFolder() } }
            } label: {
                Label(pane.path == "/" ? "/" : (pane.path as NSString).lastPathComponent,
                      systemImage: side == .local ? "laptopcomputer" : (pane.bookmark?.proto.symbol ?? "server.rack"))
            }
            .menuStyle(.borderlessButton).fixedSize().help(pane.path)
            Spacer(minLength: 8)
            if let e = pane.error {
                Text(e).foregroundStyle(.red).lineLimit(1).truncationMode(.middle).help(e)
            } else {
                Text(summary).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
            Button { newFolder = true } label: { Image(systemName: "folder.badge.plus") }.help("New folder")
            Button { confirmDelete = true } label: { Image(systemName: "trash") }.disabled(pane.selection.isEmpty).help(side == .local ? "Move to Trash" : "Delete")
            Button { Task { await pane.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 10).frame(height: 34)
        .background(.bar)
    }

    private var table: some View {
        Table(rows, selection: $pane.selection, sortOrder: $sort) {
            TableColumn("Name", value: \.name) { f in
                Label { Text(f.name).opacity(f.name.hasPrefix(".") ? 0.55 : 1) } icon: {
                    Image(nsImage: f.isDir ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(for: UTType(filenameExtension: (f.name as NSString).pathExtension) ?? .data))
                        .resizable().frame(width: 16, height: 16)
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("Size", value: \.size) { f in sizeText(f).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("Modified") { f in Text(f.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--").foregroundStyle(.secondary) }
                .width(min: 100, ideal: 140)
            TableColumn("Permissions") { f in Text(f.permissions).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            let items = pane.files.filter { ids.contains($0.id) }
            if !items.isEmpty {
                Button(side == .local ? "Upload to Server (A → B)" : "Download to Local Folder (B → A)") { transfer(items) }.disabled(!connected)
                if side == .local {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) }) }
                } else {
                    if items.count == 1, !items[0].isDir {
                        Button("Edit in Default App") { Task { await store.edit(items[0]) } }
                            .help("Opens a copy; every save is uploaded back to the server")
                    }
                    Button("Copy URL") { copyURL(items) }
                }
                Divider()
                Button(side == .local ? "Move to Trash" : "Delete…", role: .destructive) { pane.selection = ids; confirmDelete = true }
            }
            Button("New Folder…") { newFolder = true }
        } primaryAction: { ids in
            let items = pane.files.filter { ids.contains($0.id) }
            if items.count == 1, items[0].isDir { Task { await pane.open(items[0].path) } }
            else if side == .local { items.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0.path)) } }
            else { transfer(items) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard side == .remote else { return false }
            Task { await store.upload(urls) }
            return true
        }
        .overlay { if pane.busy { ProgressView().controlSize(.large) } }
    }

    private func sizeText(_ f: RemoteFile) -> Text {
        guard f.isDir else { return Text(fmtBytes(f.size)) }
        if let complete = pane.sized[f.path] { return Text((complete ? "" : "≥ ") + fmtBytes(f.size)) }
        return Text(pane.sizing && !f.isLink ? "…" : "--")
    }
    private var summary: String {
        let known = rows.filter { !$0.isDir || pane.sized[$0.path] != nil }.reduce(Int64(0)) { $0 + $1.size }
        return "\(rows.count) items · \(fmtBytes(known))\(pane.sizing ? "…" : "")"
    }
    private var ancestors: [String] {
        var out = [pane.path], p = pane.path
        while p != "/" && p != "." && !p.isEmpty { p = parentPath(p); out.append(p) }
        return out
    }
    private func transfer(_ items: [RemoteFile]) {
        let root = pane.path
        Task { await store.copy(items, from: root, to: side == .local ? .remote : .local) }
    }
    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: pane.path)
        if p.runModal() == .OK, let u = p.url { Task { await pane.open(u.path) } }
    }
    private func copyURL(_ items: [RemoteFile]) {
        guard let c = pane.bookmark else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map { c.url($0.path) }.joined(separator: "\n"), forType: .string)
    }
}

/// The strip between the panes: copy the selection across, or sync the two folders.
struct CenterStrip: View {
    @Environment(Store.self) private var store
    @AppStorage("syncMode") private var mode = SyncMode.upload
    @State private var showSync = false

    var body: some View {
        let connected = store.remote.service != nil
        VStack(spacing: 12) {
            Spacer()
            Button { let l = store.local; Task { await store.copy(l.selected, from: l.path, to: .remote) } } label: {
                Image(systemName: "arrow.right").frame(width: 22, height: 18)
            }
            .help("Copy the selection from A to B").disabled(!connected || store.local.selection.isEmpty)
            Button { let r = store.remote; Task { await store.copy(r.selected, from: r.path, to: .local) } } label: {
                Image(systemName: "arrow.left").frame(width: 22, height: 18)
            }
            .help("Copy the selection from B to A").disabled(!connected || store.remote.selection.isEmpty)
            Divider().frame(width: 30).padding(.vertical, 4)
            Button { showSync = true } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(connected ? Color.accentColor : Color.secondary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!connected || store.planning)
            .help(connected ? "Sync A and B" : "Connect to a server to sync")
            .popover(isPresented: $showSync, arrowEdge: .trailing) { options }
            if store.planning { ProgressView().controlSize(.small) }
            Spacer()
        }
        .buttonStyle(.bordered)
        .frame(width: 54)
        .background(.background.secondary)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync Folders").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow { Text("A").bold(); Text(store.local.path).lineLimit(1).truncationMode(.middle) }
                GridRow { Text("B").bold(); Text("\(store.remote.bookmark?.title ?? ""): \(store.remote.path)").lineLimit(1).truncationMode(.middle) }
            }
            .font(.caption).foregroundStyle(.secondary)
            Picker("Direction", selection: $mode) {
                ForEach(SyncMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            Toggle("Auto-upload changes from A to B", isOn: Binding(get: { store.current?.autoSync ?? false }, set: { store.setAutoSync($0) }))
                .disabled(!store.bookmarks.contains { $0.id == store.remote.bookmark?.id })
                .help("Watches folder A and uploads what changes. Needs a saved bookmark.")
            if let ex = store.current?.excludes, !ex.isEmpty {
                Label("Skipping: \(ex)", systemImage: "line.3.horizontal.decrease.circle").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Nothing is ever deleted. Files that get replaced are backed up first, so every sync can be undone. Hidden files are included only when View › Show Hidden Files is on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Dry Run") { showSync = false; Task { await store.sync(mode, dryRun: true) } }
                    .help("Compare only and show what would be copied")
                Spacer()
                Button("Sync Now") { showSync = false; Task { await store.sync(mode, dryRun: false) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
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
                Text("A  \(plan.localRoot)\nB  \(plan.remoteRoot)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 28) {
                    stat("arrow.up.circle.fill", .orange, "Upload A → B", plan.files(to: .remote).count, plan.bytes(to: .remote))
                    stat("arrow.down.circle.fill", .blue, "Download B → A", plan.files(to: .local).count, plan.bytes(to: .local))
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
                        Image(systemName: op.isDir ? "folder.badge.plus" : op.to == .remote ? "arrow.up" : "arrow.down")
                            .foregroundStyle(op.isDir ? Color.green : op.to == .remote ? Color.orange : Color.blue)
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
            if store.planning || store.remote.busy { ProgressView().controlSize(.small) }
            Text(store.message.isEmpty ? " " : store.message).lineLimit(1).truncationMode(.tail)
            Spacer()
            if store.showHidden { Label("Hidden files shown", systemImage: "eye").labelStyle(.titleAndIcon) }
            if let c = store.remote.bookmark { Image(systemName: "lock.fill").opacity(c.proto == .ftp || c.proto == .webdav ? 0 : 1); Text(c.proto.rawValue) }
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
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
        let id = pick ?? store.remote.bookmark?.id ?? store.bookmarks.first?.id
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
        Button("Duplicate") { var c = b; c.id = UUID(); c.nickname = b.title + " copy"; store.bookmarks.append(c) }
        Divider()
        Button("Delete Bookmark", role: .destructive) { Keychain.set(b, ""); store.bookmarks.removeAll { $0.id == b.id } }
    }
}

struct BookmarksView: View {
    @Environment(Store.self) private var store
    @Binding var editing: Bookmark?
    private let cols = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 16) {
                ForEach(store.bookmarks) { b in
                    BookmarkCard(b: b)
                        .onTapGesture(count: 2) { Task { await store.connect(b) } }
                        .contextMenu { BookmarkMenu(b: b, editing: $editing) }
                }
                Button { editing = Bookmark() } label: {
                    VStack(spacing: 8) { Image(systemName: "plus").font(.title); Text("New Bookmark") }
                        .frame(maxWidth: .infinity, minHeight: 96)
                        .foregroundStyle(.secondary)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.quaternary))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
    }
}

struct BookmarkCard: View {
    @Environment(Store.self) private var store
    let b: Bookmark
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: b.proto.symbol).font(.title2).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.tint, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(b.title).font(.headline).lineLimit(1)
                Text(b.proto == .local ? b.path : "\(b.user.isEmpty ? "" : b.user + "@")\(b.host)").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(b.proto.rawValue).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button { Task { await store.connect(b) } } label: { Image(systemName: "arrow.right.circle.fill").font(.title2) }
                .buttonStyle(.plain).foregroundStyle(.tint).help("Connect")
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
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
                TextField("Path", text: $bookmark.path, prompt: Text(bookmark.proto == .local ? NSHomeDirectory() : "Home folder"))
                if !isExisting { Toggle("Add to Bookmarks", isOn: $saveBookmark) }
                Section("Sync") {
                    TextField("Exclude", text: Binding(get: { bookmark.excludes ?? "" }, set: { bookmark.excludes = $0.isEmpty ? nil : $0 }),
                              prompt: Text("node_modules, .git, *.log"))
                    LabeledContent("Local folder (A)") {
                        HStack {
                            Text(bookmark.syncLocal ?? "Not paired yet").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") {
                                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                                if p.runModal() == .OK, let u = p.url { bookmark.syncLocal = u.path }
                            }
                        }
                    }
                    TextField("Server folder (B)", text: Binding(get: { bookmark.syncRemote ?? "" }, set: { bookmark.syncRemote = $0.isEmpty ? nil : $0 }),
                              prompt: Text("Set by your first sync"))
                    Toggle("Auto-upload changes from A to B", isOn: Binding(get: { bookmark.autoSync ?? false }, set: { bookmark.autoSync = $0 }))
                        .disabled(bookmark.syncLocal == nil || bookmark.syncRemote == nil)
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
