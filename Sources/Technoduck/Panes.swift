import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(Store.self) private var store
    @State private var editing: Bookmark?
    @State private var quick = ""

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar(editing: $editing).font(store.theme.font)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            // Dividers between panes can be dragged; a pane's grip (≡) drags the pane itself to another spot.
            HSplitView {
                ForEach(Array(store.panes.enumerated()), id: \.element.id) { i, p in
                    HStack(spacing: 0) {
                        if i > 0 { CenterStrip(left: store.panes[i - 1], right: p); Divider() }
                        // Clipped, so a table wider than its pane can't push the strip out of view.
                        PaneView(pane: p, editing: $editing).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
                    }
                    .frame(minWidth: i > 0 ? 360 : 300, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
            .id(store.panes.map(\.id))
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
            .font(store.theme.font)
        }
        .inspector(isPresented: $store.showInspector) {
            InspectorView().font(store.theme.font).inspectorColumnWidth(min: 280, ideal: 330)
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
                Button { store.addPane() } label: { Label("Add Browser", systemImage: "rectangle.split.3x1") }
                    .help("Add a browser pane (up to 4)").disabled(store.panes.count >= 4)
                Button { store.showInspector.toggle() } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .help("Transfers and timeline")
            }
        }
        .tint(store.theme.accent)
        .onChange(of: store.theme, initial: true) {
            NSApp.appearance = store.theme.appearance
            // SwiftUI's .grayscale on the split view breaks the toolbar's safe area, so the window frame gets a Core Image filter.
            for w in NSApp.windows where w.sheetParent == nil { w.contentView?.superview?.setGreyscale(store.theme.grayscale > 0) }
        }
        .sheet(item: $editing) { b in ConnectionSheet(bookmark: b).themed(store.theme) }
        .sheet(item: $store.plan) { p in SyncPlanSheet(plan: p).themed(store.theme) }
        .navigationTitle("Technoduck")
        .navigationSubtitle(store.active?.title ?? "")
    }
}

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Binding var editing: Bookmark?

    var body: some View {
        @Bindable var store = store
        List {
            Section("Favorites") {
                if store.favorites.isEmpty {
                    Text("Right-click a folder › Add to Favorites").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(store.favorites) { f in FavoriteRow(f: f) }
                    .onMove { store.favorites.move(fromOffsets: $0, toOffset: $1) }
            }
            Section("Bookmarks") {
                ForEach(store.bookmarks) { b in
                    Button { Task { await store.connect(b) } } label: {
                        Label { Text(b.title).lineLimit(1) } icon: { Image(systemName: b.proto.symbol) }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(store.panes.contains { $0.bookmark?.id == b.id } ? .semibold : .regular)
                    .contextMenu { BookmarkMenu(b: b, editing: $editing) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(store.theme.sidebar == nil ? .automatic : .hidden)
        .background(store.theme.sidebar ?? .clear)
    }
}

/// A favorite folder: where it lives in bold (this Mac or the server's domain), the end of its path in grey.
struct FavoriteRow: View {
    @Environment(Store.self) private var store
    let f: Favorite

    var body: some View {
        let b = store.bookmarks.first { $0.id == f.bookmarkID }
        let place = f.bookmarkID == nil ? "This Mac" : b.map { $0.host.isEmpty ? $0.title : $0.host } ?? "Deleted server"
        Button { Task { await store.open(f) } } label: {
            HStack(spacing: 8) {
                Image(systemName: f.bookmarkID == nil ? "laptopcomputer" : b?.proto.symbol ?? "questionmark.folder")
                    .foregroundStyle(f.bookmarkID == nil ? Color.secondary : store.theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(place).fontWeight(.semibold).lineLimit(1)
                    // Head truncation keeps the last folders visible, with "…" standing in for the rest.
                    Text(f.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(b.map { $0.url(f.path) } ?? f.path)
        .contextMenu {
            Button("Open") { Task { await store.open(f) } }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(b.map { $0.url(f.path) } ?? f.path, forType: .string) }
            Divider()
            Button("Remove from Favorites", role: .destructive) { store.favorites.removeAll { $0.id == f.id } }
        }
    }
}

/// One file browser: path bar on top, files below. Empty panes offer the bookmarks.
struct PaneView: View {
    @Environment(Store.self) private var store
    @Bindable var pane: Pane
    @Binding var editing: Bookmark?
    @State private var sort = [KeyPathComparator(\RemoteFile.name)]
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var confirmDelete = false
    @State private var dropping = false

    private var rows: [RemoteFile] { store.visible(pane.files).sorted(using: sort).sorted { $0.isDir && !$1.isDir } }
    private var isActive: Bool { store.active === pane }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if pane.service == nil { EmptyPane(pane: pane, editing: $editing) } else { table }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if dropping { RoundedRectangle(cornerRadius: 4).strokeBorder(store.theme.accent, lineWidth: 3).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL, .utf8PlainText], isTargeted: $dropping) { providers in
            let target = pane
            Task { let (urls, refs) = await loadDrop(providers); await store.drop(urls: urls, into: target); await store.drop(refs: refs, into: target) }
            return true
        }
        .simultaneousGesture(TapGesture().onEnded { store.activeID = pane.id })
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { let n = folderName; folderName = ""; Task { await store.mkdir(n, in: pane) } }
            Button("Cancel", role: .cancel) { folderName = "" }
        }
        .confirmationDialog(pane.isLocal ? "Move \(pane.selected.count) item(s) to the Trash?" : "Delete \(pane.selected.count) item(s)? This cannot be undone on the server.",
                            isPresented: $confirmDelete) {
            Button(pane.isLocal ? "Move to Trash" : "Delete", role: .destructive) {
                let items = pane.selected; pane.selection = []
                Task { await store.delete(items, in: pane) }
            }
        }
        .onChange(of: pane.path) { pane.selection = [] }
        .onChange(of: pane.selection) { if !pane.selection.isEmpty { store.activeID = pane.id } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                .frame(width: 14, height: 22).contentShape(Rectangle())
                .draggable("technoduck-pane:\(pane.id.uuidString)")
                .help("Drag onto another pane to swap places")
            Image(systemName: pane.service == nil ? "circle.dashed" : pane.isLocal ? "laptopcomputer" : (pane.bookmark?.proto.symbol ?? "server.rack"))
                .foregroundStyle(isActive ? store.theme.accent : Color.secondary)
            if pane.service != nil {
                Button { Task { await pane.back() } } label: { Image(systemName: "chevron.left") }.disabled(pane.history.isEmpty).help("Back")
                Button { Task { await pane.open(parentPath(pane.path)) } } label: { Image(systemName: "chevron.up") }.disabled(pane.path == "/").help("Enclosing folder")
                Menu {
                    ForEach(ancestors, id: \.self) { p in Button(p) { Task { await pane.open(p) } } }
                    if pane.isLocal { Divider(); Button("Choose Folder…") { chooseFolder() } }
                } label: {
                    Text("\(pane.title) — \(pane.path == "/" ? "/" : (pane.path as NSString).lastPathComponent)").fontWeight(isActive ? .semibold : .regular)
                }
                .menuStyle(.borderlessButton).fixedSize().help(pane.path)
                Spacer(minLength: 6)
                if let e = pane.error {
                    Text(e).foregroundStyle(.red).lineLimit(1).truncationMode(.middle).help(e)
                } else {
                    Text(summary).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                }
                Button { store.toggleFavorite(pane, pane.path) } label: {
                    Image(systemName: store.favorite(pane, pane.path) == nil ? "star" : "star.fill")
                }
                .help("Favorite this folder").disabled(!store.canFavorite(pane))
                Button { newFolder = true } label: { Image(systemName: "folder.badge.plus") }.help("New folder")
                Button { confirmDelete = true } label: { Image(systemName: "trash") }.disabled(pane.selection.isEmpty).help(pane.isLocal ? "Move to Trash" : "Delete")
                Button { Task { await pane.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            } else {
                Text("Choose a location").foregroundStyle(.secondary)
                Spacer()
            }
            Menu {
                if pane.service != nil {
                    if let b = saved {
                        Button("Back Up \(b.title) Now", systemImage: "externaldrive.badge.timemachine") { Task { await store.backUp(b) } }
                        Button("Set Current Folder as Start Folder", systemImage: "house") { store.setStartFolder(pane.path, for: pane) }
                    }
                    Button(pane.isLocal ? "Close Location" : "Disconnect", systemImage: "eject") { pane.close() }
                }
                if store.panes.count > 1 { Button("Close Pane", systemImage: "xmark") { store.closePane(pane) } }
                if store.panes.count < 4 { Button("Add Browser Pane", systemImage: "plus") { store.addPane() } }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .buttonStyle(.borderless)
        .font(store.theme.font ?? .callout)
        .padding(.horizontal, 10).frame(height: 34)
        .themeBackground(store.theme.bar, .bar)
        .overlay(alignment: .top) {
            if isActive {
                if store.theme == .mac512 { // the pinstripes of an active 1984 title bar
                    VStack(spacing: 1) { ForEach(0..<3, id: \.self) { _ in Rectangle().frame(height: 1) } }
                } else { Rectangle().fill(store.theme.gradient).frame(height: 2) }
            }
        }
    }

    private var saved: Bookmark? { store.bookmarks.first { $0.id == pane.bookmark?.id } }

    private var table: some View {
        Table(of: RemoteFile.self, selection: $pane.selection, sortOrder: $sort) {
            TableColumn("Name", value: \.name) { f in
                Label { Text(f.name).opacity(f.name.hasPrefix(".") ? 0.55 : 1) } icon: {
                    Image(nsImage: f.isDir ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(for: UTType(filenameExtension: (f.name as NSString).pathExtension) ?? .data))
                        .resizable().frame(width: 16, height: 16)
                }
            }
            .width(min: 100, ideal: 240)
            TableColumn("Size", value: \.size) { f in sizeText(f).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 56, ideal: 80)
            TableColumn("Modified") { f in Text(f.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--").foregroundStyle(.secondary) }
                .width(min: 80, ideal: 140)
            TableColumn("Permissions") { f in Text(f.permissions).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                .width(min: 50, ideal: 90)
        } rows: {
            ForEach(rows) { f in TableRow(f).itemProvider { dragItem(f) } }
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            let items = pane.files.filter { ids.contains($0.id) }
            if !items.isEmpty {
                let others = store.panes.filter { $0 !== pane && $0.service != nil }
                if !others.isEmpty {
                    Menu("Copy To") {
                        ForEach(others) { o in Button("\(o.title) — \(o.path)") { copy(items, to: o) } }
                    }
                }
                if items.count == 1, items[0].isDir {
                    Button(store.favorite(pane, items[0].path) == nil ? "Add to Favorites" : "Remove from Favorites") { store.toggleFavorite(pane, items[0].path) }
                        .disabled(!store.canFavorite(pane))
                    if store.canSetStart(pane) {
                        Button("Set as Start Folder for \(pane.title)") { store.setStartFolder(items[0].path, for: pane) }
                    }
                }
                if pane.isLocal {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) }) }
                } else {
                    if items.count == 1, !items[0].isDir {
                        Button("Edit in Default App") { Task { await store.edit(items[0], in: pane) } }
                            .help("Opens a copy; every save is uploaded back to the server")
                    }
                    Button("Copy URL") { copyURL(items) }
                }
                Divider()
                Button(pane.isLocal ? "Move to Trash" : "Delete…", role: .destructive) { pane.selection = ids; confirmDelete = true }
            }
            Button("New Folder…") { newFolder = true }
        } primaryAction: { ids in
            let items = pane.files.filter { ids.contains($0.id) }
            if items.count == 1, items[0].isDir { Task { await pane.open(items[0].path) } }
            else if pane.isLocal { items.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0.path)) } }
            else if let o = store.panes.first(where: { $0 !== pane && $0.isLocal }) { copy(items, to: o) }
        }
        .scrollContentBackground(store.theme.canvas == nil ? .automatic : .hidden)
        .alternatingRowBackgrounds(store.theme.canvas == nil ? .automatic : .disabled)
        .background(store.theme.canvas ?? .clear)
        .overlay { if pane.busy { ProgressView().controlSize(.large) } }
    }

    /// Files on this Mac drag as real files (so Finder takes them too); server files as a reference to this pane.
    private func dragItem(_ f: RemoteFile) -> NSItemProvider {
        if pane.isLocal, let p = NSItemProvider(contentsOf: URL(fileURLWithPath: f.path)) { return p }
        return NSItemProvider(object: "technoduck-item:\(pane.id.uuidString):\(f.path)" as NSString)
    }
    private func copy(_ items: [RemoteFile], to other: Pane) {
        guard let e = pane.endpoint else { return }
        Task { await store.copy(items, from: e, to: other) }
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

/// Reads what was dropped: file URLs (Finder, or a pane on this Mac) and Technoduck references (server panes, pane grips).
func loadDrop(_ providers: [NSItemProvider]) async -> (urls: [URL], refs: [String]) {
    var urls: [URL] = [], refs: [String] = []
    for p in providers {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) {
            if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { urls.append(u) } else if let u = item as? URL { urls.append(u) }
        } else if p.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier), let item = try? await p.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier) {
            if let d = item as? Data, let s = String(data: d, encoding: .utf8) { refs.append(s) } else if let s = item as? String { refs.append(s) }
        }
    }
    return (urls, refs)
}

/// A pane without a location: pick this Mac or a bookmark.
struct EmptyPane: View {
    @Environment(Store.self) private var store
    let pane: Pane
    @Binding var editing: Bookmark?
    private let cols = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 14) {
                Button { Task { await store.openLocal(in: pane) } } label: {
                    LocationCard(symbol: "laptopcomputer", title: "This Mac", subtitle: homeDir, kind: "Local Disk")
                }
                .buttonStyle(.plain)
                ForEach(store.bookmarks) { b in
                    Button { Task { await store.connect(b, in: pane) } } label: {
                        LocationCard(symbol: b.proto.symbol, title: b.title,
                                     subtitle: b.proto == .local ? b.path : "\(b.user.isEmpty ? "" : b.user + "@")\(b.host)", kind: b.proto.rawValue)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { BookmarkMenu(b: b, editing: $editing) }
                }
                Button { editing = Bookmark() } label: {
                    VStack(spacing: 8) { Image(systemName: "plus").font(.title); Text("New Bookmark") }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .foregroundStyle(.secondary)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.quaternary))
                        .contentShape(RoundedRectangle(cornerRadius: 12))  // the whole tile is the button, not just the + and label
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(store.theme.canvas ?? .clear)
    }
}

struct LocationCard: View {
    @Environment(Store.self) private var store
    let symbol: String, title: String, subtitle: String, kind: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(store.theme.onAccent)
                .frame(width: 42, height: 42).background(LinearGradient(colors: [store.theme.accent, store.theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(kind).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The strip between two panes: copy the selection across, or sync the two folders.
struct CenterStrip: View {
    @Environment(Store.self) private var store
    let left: Pane, right: Pane
    @AppStorage("syncMode") private var mode = SyncMode.upload
    @State private var showSync = false

    var body: some View {
        let ready = left.service != nil && right.service != nil
        VStack(spacing: 12) {
            Spacer()
            Button { copy(left, right) } label: { Image(systemName: "arrow.right").frame(width: 22, height: 18) }
                .help("Copy the selection to the right").disabled(!ready || left.selection.isEmpty)
            Button { copy(right, left) } label: { Image(systemName: "arrow.left").frame(width: 22, height: 18) }
                .help("Copy the selection to the left").disabled(!ready || right.selection.isEmpty)
            Divider().frame(width: 30).padding(.vertical, 4)
            Button { showSync = true } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3.weight(.semibold)).foregroundStyle(ready ? store.theme.onAccent : .white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(ready ? AnyShapeStyle(LinearGradient(colors: [store.theme.accent, store.theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.secondary.opacity(0.4))))
            }
            .buttonStyle(.plain)
            .disabled(!ready || store.planning)
            .help(ready ? "Sync these two folders" : "Open a location on both sides to sync")
            .popover(isPresented: $showSync, arrowEdge: .trailing) { options }
            if store.planning { ProgressView().controlSize(.small) }
            Spacer()
        }
        .buttonStyle(.bordered)
        .frame(width: 54)
        .themeBackground(store.theme.strip, .background.secondary)
    }

    private func copy(_ from: Pane, _ to: Pane) {
        guard let e = from.endpoint else { return }
        let items = from.selected
        Task { await store.copy(items, from: e, to: to) }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync Folders").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow { Text("A").bold(); Text("\(left.title): \(left.path)").lineLimit(1).truncationMode(.middle) }
                GridRow { Text("B").bold(); Text("\(right.title): \(right.path)").lineLimit(1).truncationMode(.middle) }
            }
            .font(.caption).foregroundStyle(.secondary)
            Picker("Direction", selection: $mode) {
                ForEach(SyncMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if let b = store.pairable(left, right) {
                Toggle("Auto-upload changes from this Mac to \(b.title)", isOn: Binding(get: { store.autoSyncOn(left, right) }, set: { store.setAutoSync($0, left, right) }))
                    .help("Watches the folder on this Mac and uploads what changes, as long as Technoduck is open.")
            }
            let ex = [left.bookmark, right.bookmark].compactMap { b in store.bookmarks.first { $0.id == b?.id }?.excludes }.filter { !$0.isEmpty }
            if !ex.isEmpty {
                Label("Skipping: \(ex.joined(separator: ", "))", systemImage: "line.3.horizontal.decrease.circle").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Nothing is ever deleted. Files that get replaced are backed up first, so every sync can be undone. Hidden files are included only when View › Show Hidden Files is on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Dry Run") { showSync = false; Task { await store.sync(mode, left, right, dryRun: true) } }
                    .help("Compare only and show what would be copied")
                Spacer()
                Button("Sync Now") { showSync = false; Task { await store.sync(mode, left, right, dryRun: false) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
