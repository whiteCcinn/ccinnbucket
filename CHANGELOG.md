# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/whiteCcinn/ccinnbucket/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/whiteCcinn/ccinnbucket/releases/tag/v1.0.0
