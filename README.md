<p align="center"><img src="Resources/AppIcon.png" width="160" alt="Technoduck icon"></p>

# Technoduck

A native macOS file-transfer client written in Swift and SwiftUI, with a local folder and a server folder side by side.

**Protocols:** SFTP, FTP, FTPS, WebDAV (HTTP/HTTPS) and local disk.

**Website:** [gerbenhoogendam.github.io/technoduck](https://gerbenhoogendam.github.io/technoduck/) (source in `docs/`).

## Download

**[Download Technoduck for Mac](https://github.com/gerbenhoogendam/technoduck/releases/latest)**: a universal app for Apple silicon and Intel Macs with macOS 14 or later, signed and notarised by Apple. Unzip it and move Technoduck to your Applications folder.

## Features

- **Up to four browsers:** each pane shows your Mac or any server. Drag the dividers to resize, drag a pane's ≡ grip to move it, and drag files between panes or in from Finder.
- **Sync between any two neighbouring panes:** A → B, B → A, or both ways (newest wins). A **Dry Run** compares only and lists every file that would be copied, with totals per direction.
- **Undo:** files that get replaced are backed up first, so any sync or copy can be rolled back from the Transfers or Timeline panel. A sync never deletes anything.
- **Timeline per connection:** uploads, downloads, syncs, deletes and undos, grouped by day.
- **Folder sizes:** every folder's total size is worked out in the background.
- **Hidden files:** View › Show Hidden Files (⇧⌘.).
- **Themes:** View › Theme › Nova Midnight, Nova Daylight or Neon Pond, after Panic's Nova editor, or Macintosh 512K in greyscale and Chicago.
- **Settings (⌘,):** theme, hidden files, folder sizes on or off, whether Activity opens when a transfer starts, a sound when a sync finishes, how many syncs can be undone (and clearing those backups), and iCloud bookmarks.
- **Excludes:** per bookmark, e.g. `node_modules, .git, *.log`.
- **Folder pairs and auto-upload:** each bookmark remembers its local and server folders, and can upload changes as soon as you save.
- **Favorites:** any folder, on your Mac or a server, can be pinned in the sidebar.
- **Start folder:** right-click a server folder › Set as Start Folder.
- **One-click backup:** back up a server into a folder you choose, as dated snapshots. Unchanged files are APFS clones of the previous snapshot, so only changes are downloaded.
- **Bookmarks in iCloud Drive:** Bookmarks › Sync Bookmarks with iCloud Drive, with a daily backup you can restore. Passwords stay in each Mac's Keychain.
- **Edit in your own app:** open a server file in its default app; every save is uploaded back to the server.

Passwords are stored in the macOS Keychain. SFTP uses the system `sftp` (your SSH keys work), and FTP/FTPS use the system `curl`.

## Build

Requires macOS 14 or later and Swift 5.9 or later.

```sh
./build-app.sh                       # builds Technoduck.app
NOTARY_PROFILE=<profile> ./release.sh  # universal, signed and notarised: Technoduck-<version>.zip
.build/release/Technoduck --self-test
```

`Cargo.toml` and `launcher/` only exist so a Cargo-based checker can build and start the Swift app. You don't need them.

## License

MIT — see [LICENSE](LICENSE). The ChicagoFLF font by Robin Casady is in the public domain; see [Resources/README.ChicagoFLF](Resources/README.ChicagoFLF).
