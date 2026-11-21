import SwiftUI

/// Technoduck › Settings… (⌘,).
struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var backupSize: Int64?
    @State private var confirmClear = false

    var body: some View {
        @Bindable var store = store
        TabView {
            Form {
                Picker("Theme", selection: $store.theme) {
                    ForEach(Theme.allCases) { t in
                        HStack { Swatch(theme: t); Text(t.title) }.tag(t)
                    }
                }
                .pickerStyle(.radioGroup)
                Section {
                    Toggle("Show hidden files", isOn: $store.showHidden)
                    Toggle("Calculate folder sizes", isOn: $store.folderSizes)
                } footer: {
                    Text("Folder sizes are worked out in the background. Turn this off for very large or slow servers.").foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Toggle("Show Activity when a transfer starts", isOn: $store.autoShowActivity)
                Toggle("Play a sound when a sync finishes", isOn: $store.doneSound)
                Section {
                    Picker("Undo history", selection: $store.undoLimit) {
                        ForEach([10, 30, 100], id: \.self) { Text("Last \($0) syncs").tag($0) }
                    }
                    LabeledContent("Backups for undo") {
                        Text(backupSize.map(fmtBytes) ?? "…").monospacedDigit()
                        Button("Clear…") { confirmClear = true }.disabled(store.records.isEmpty && backupSize == 0)
                    }
                } footer: {
                    Text("Before a sync replaces a file, the old version is kept so the sync can be undone.").foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
            .confirmationDialog("Clear the undo history?", isPresented: $confirmClear) {
                Button("Clear Undo History", role: .destructive) { store.clearUndoHistory(); backupSize = 0 }
            } message: {
                Text("Past syncs can no longer be undone. Your files are not changed.")
            }

            Form {
                Toggle("Sync bookmarks with iCloud Drive", isOn: Binding(get: { store.iCloud }, set: { store.setICloud($0) }))
                LabeledContent("Daily backups") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: store.libraryBackups, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(store.libraryBackups)
                    }
                    Button("Restore…") { store.restoreLibrary() }
                }
                Text("Passwords are not synced; they stay in each Mac's Keychain.").foregroundStyle(.secondary)
            }
            .tabItem { Label("Bookmarks", systemImage: "bookmark") }
        }
        .formStyle(.grouped)
        .scrollContentBackground(store.theme.canvas == nil ? .automatic : .hidden)
        .background(store.theme.canvas ?? .clear)
        .frame(width: 480, height: 400)
        .tint(store.theme.accent)
        .themed(store.theme)
        // shortcut: measured on the main thread; fine for the 30-ish backups kept, move off-main if it ever stalls.
        .task { backupSize = store.undoBackupSize() }
    }
}

/// The theme's two accent colours on its canvas, as a small preview.
private struct Swatch: View {
    let theme: Theme
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(theme.canvas ?? Color(nsColor: .windowBackgroundColor))
            .overlay(Capsule().fill(theme.gradient).frame(width: 18, height: 5))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .frame(width: 30, height: 18)
    }
}
