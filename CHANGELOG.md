# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.3.0] - 2026-11-19

### Added

- **Column view.** Switch between a list and Finder-style columns with the toolbar or **View ▸ as List / as Columns** (⌘2 / ⌘3); the choice is remembered.
  - Every folder on the path is a column; selecting a folder opens it in the next column, selecting files selects them in their column's folder.
  - ← and → move between columns, ↑ and ↓ within one (moving onto a folder opens it); Return, Space, ⌘⌫ and type-to-select work as in the list.
  - Each column pages through large folders on its own and stays smooth with 50,000 entries. Moving between columns reuses listings already on screen.
  - With nothing selected, the toolbar and the Object menu act on the current folder, as in Finder. Drops, New Folder and Upload act on the column's folder. A **Sort By** menu replaces the column headers.
- **gzip and Zstandard previews of any size.** `.gz`, `.gzip`, `.tgz`, `.zst`, `.zstd` and `.tzst` objects are decompressed while they stream from the start of the object; JSON inside is indented.
  - Live progress while a preview loads: downloaded of total, decompressed bytes and percentage. QuickLook downloads show progress too.
  - The preview window shows the first 8 MB; **Show More** adds 8 MB at a time.
  - Pure-Swift decoders and encoders for gzip (RFC 1952) and Zstandard (RFC 8878), with no third-party code, fuzz-tested and checked against the `gzip` and `zstd` command-line tools.
- **Copy and edit text in the preview window.** Select and copy any text, **Copy All** the exact stored text, ⌘F to find, Formatted/Raw for JSON.
  - On writable accounts, complete UTF-8 text up to 16 MB can be edited in place. **Save…** (⌘S) asks twice before anything is uploaded, shows the size change and warns when JSON does not parse.
  - Saving compresses again as gzip or Zstandard, keeps headers, user metadata, storage class, encryption and tags, and is refused if the object changed since it was opened.
  - Minified JSON is edited indented and saved minified again, so only what you change is changed.
  - Not offered where saving would lose structure: OSS appendable objects, BGZF/tabix gzip, multi-frame or seekable Zstandard. The confirmation lists what is not copied (ACL, Object Lock retention and legal hold, website redirects).
- **Export and import connections.** **File ▸ Export Connections…** saves every connection and your preferences to one `.ccinnbucket` file. With a passphrase, everything — connections, preferences and secret keys — is sealed (AES-256-GCM with a PBKDF2-SHA256 key, 600,000 rounds), so nothing can be read or altered without it. **Import Connections…** (also on the welcome screen) shows what will be added or updated, with the settings that change, and imports everything with one click; secrets go to the Keychain. Changes that would redirect an existing connection or widen its access are not applied from a file without a passphrase unless you turn them on.

### Fixed

- The inspector's Open Preview, Share, Download and Edit buttons did nothing when clicked: inside the inspector, macOS placed the controls one toolbar height below where they were drawn. The inspector now lays out its content so clicks reach the buttons, and its buttons have full-size hit areas.
- Previewing a `.gz` downloaded the whole object (up to 100 MB) with no progress and then showed only an archive icon.
- Very long lines (minified JSON, one-line CSV) could hang the preview; they are shortened for display while Copy All copies the full text.
- Keyboard shortcuts of the window menus (⌘↑, ⌘⌫, ⌘R, ⌘[ …) acted on the browser behind an open sheet; they are disabled while a sheet or dialog is open.
- A cancelled listing could end the loading state of the listing that replaced it, or let two page loads run at once.

## [1.2.0] - 2026-11-17

### Added

- **Multiple windows, each with its own connection.**
  - **File ▸ New Window with This Connection** (⌥⌘N; ⇧⌘N stays New Folder) opens another window connected to the same account with the credentials in use. It also works for accounts opened from launch arguments and for secrets that are not in the Keychain; the credentials stay in memory and are never saved.
  - A **New Window** toolbar button on the account screen and in the workspace. In the workspace it is a split button: click to duplicate the connection, or choose an empty window from its menu.
  - **Open in New Window** in a saved account's context menu.
  - **File ▸ New Window** (⌘N) still opens the account screen. Closing a window disconnects only that window.
  - Only windows opened in this session connect on their own. A window that macOS restores from an earlier session opens at the account screen.

### Fixed

- Closing a window while it is still connecting cancels the connection instead of finishing it in the background.
- A connection error is shown on the account screen even when no account is selected.
- Launch arguments such as `--open-settings` apply to the first window only, not to every new window.

## [1.1.0] - 2026-11-16

### Added

- **Check for Updates…** in the app menu. When a newer release exists, CcinnBucket shows its version and release notes. **Download & Open** downloads the disk image, verifies its size and SHA-256 against the release's `SHA256SUMS.txt`, saves it to Downloads without overwriting anything, and opens it. **Release Page**, **Skip This Version** and **Later** are also available.
- A quiet automatic check at most once a day (retried after an hour when offline), on by default, switchable in **Settings → General → Updates**.
- Project links: the Help menu now has **CcinnBucket on GitHub**, **Release Notes** and **Report an Issue…**; the About window shows the GitHub link; Settings → General shows the version and project links.

## [1.0.0] - 2026-11-15

First public release.

### Added

- Pure-Swift object-storage stack with no third-party dependencies: AWS Signature V4 (headers and presigned URLs), OSS Signature V4 (`OSS4-HMAC-SHA256`) and legacy OSS V1, STS session tokens, all verified against vectors generated with the official SDKs.
- Amazon S3 (virtual-hosted and path-style addressing, automatic bucket-region discovery and redirects), S3-compatible services with presets for MinIO, Cloudflare R2, Ceph RGW, Wasabi and Tencent Cloud COS, and the native Alibaba Cloud OSS API (public, internal and accelerated endpoints, custom domains).
- Resilient transport: retries with exponential backoff and full jitter, clock-skew correction, cancellation, bounded XML parsing and bounded in-memory bodies, streaming downloads to disk.
- Account manager with favourites, recents, colour tags, connection testing, Keychain-backed secrets, per-account read-only mode and read-only import from AWS, Alibaba Cloud and ossutil configuration files.
- Bucket list with create and delete; object browser with prefix folders, breadcrumbs, back/forward, ListObjectsV2 paging (V1 fallback), a virtualized table that stays smooth with 50,000+ objects, filtering, sorting and multi-select.
- Inspector with metadata, tags, versions and encryption; previews for text (ranged), JSON, images, PDFs and QuickLook types; metadata, storage-class and tag editing through self-copy.
- Drag-and-drop uploads of files and folders with parallel, memory-bounded multipart uploads, pause/resume/cancel and abort; listing and aborting incomplete multipart uploads; resumable parallel ranged downloads; a transfer queue with per-item and overall throughput.
- Server-side copy, move and rename (multipart copy above the provider limit), new folders, batch delete with a count confirmation, presigned links with an expiry picker, object versions and delete markers with restore.
- Bucket settings: versioning toggle, and lifecycle, CORS, policy, ACL and default encryption summaries.
- **MCP server for AI clients.** `CcinnBucket.app/Contents/MacOS/CcinnBucket mcp [--profile <name|id>] [--read-only]` runs a headless Model Context Protocol server over stdio with the tools `list_connections`, `list_buckets`, `list_objects`, `head_object`, `read_object_text` and `object_versions`, plus `put_text_object`, `delete_objects`, `copy_object` and `presign_url` for accounts with read & write access.
- Per-account **AI access via MCP** (Disabled / Read-only / Read & write, disabled by default) in the account editor and in **Settings → MCP**, with copy-ready setup for Claude Code, Codex and Claude Desktop; app-enforced limits and an audit log in `mcp-audit.jsonl`.

[Unreleased]: https://github.com/whiteCcinn/ccinnbucket/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/whiteCcinn/ccinnbucket/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/whiteCcinn/ccinnbucket/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/whiteCcinn/ccinnbucket/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/whiteCcinn/ccinnbucket/releases/tag/v1.0.0
