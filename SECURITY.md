# Security Policy

## Supported versions

Security fixes are released for the latest minor version of CcinnBucket.

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/whiteCcinn/ccinnbucket/security/advisories/new). Include:

- a description of the issue and its impact,
- steps to reproduce (storage service, region and endpoint type, sample keys if relevant),
- any suggested fix.

You can expect an acknowledgement within a few days. Once a fix is available, we will publish a release and an advisory crediting the reporter (unless you prefer to remain anonymous).

## Scope and design notes

- Secret access keys and session tokens are stored in the macOS Keychain; the saved account file never contains them.
- Importing from `~/.aws`, `~/.alibabacloud`, `~/.ossutilconfig` and `~/.aliyun/config.json` only reads those files; CcinnBucket never writes to them.
- An account in read-only mode rejects every mutating request in the storage layer, before anything is signed or sent. A way to change data through a read-only account is a security vulnerability.
- Presigned URLs are signed locally and grant access to whoever holds them until they expire (at most 7 days for SigV4).
- The MCP server (`CcinnBucket mcp`) only uses accounts the user enabled for AI access and enforces read-only access and its documented limits itself; presigning counts as a write-level action. Any way for an MCP client to use a disabled account, write or presign through a read-only account, exceed the documented limits, or obtain secret keys or session tokens is a security vulnerability.
- XML responses are parsed with DTDs and entities rejected and with size and depth limits.
- Update checks contact only `api.github.com` and `github.com`, send no personal data (the User-Agent is `CcinnBucket/<version>`), and run at most once a day unless you check manually. A downloaded disk image is accepted only from this repository's download URL for the same release tag, at the size the release lists, and with the SHA-256 published in that release's `SHA256SUMS.txt`. The checksum guards against corruption and truncation, not against a compromised GitHub release; authenticity relies on HTTPS to github.com. The app never replaces itself; you drag the new version into Applications.
