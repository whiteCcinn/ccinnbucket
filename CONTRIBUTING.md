# Contributing to CcinnBucket

Thanks for taking the time to contribute! This document explains how to set up a development environment and what we expect from changes.

## Development setup

- macOS 14 or later, Xcode 16 or later (Swift 6).
- Docker, if you want to run the integration tests against a local MinIO server.

```bash
git clone https://github.com/whiteCcinn/ccinnbucket.git
cd ccinnbucket
swift build
swift test --skip IntegrationTests
scripts/build-app.sh --open
```

### Integration tests

```bash
eval "$(scripts/storage-up.sh)"       # MinIO on 127.0.0.1:19900 with seeded buckets
swift build                           # the MCP tests launch .build/debug/CcinnBucket mcp
swift test --filter IntegrationTests
scripts/storage-down.sh
```

The containers are named `ccinnbucket-it-*` and only listen on `127.0.0.1`. Never point the integration tests at a real cloud account.

The MCP tests point the server at a temporary folder with the test-only variables `CCINNBUCKET_ACCOUNTS_DIR` and `CCINNBUCKET_TEST_INSECURE_SECRETS` (secrets passed as JSON instead of the Keychain). Never use them with real credentials.

### Signing vectors

Signature tests compare against reference values produced by the official SDKs, never hand-computed ones:

```bash
python3 -m venv /tmp/ccinnbucket-vectors
/tmp/ccinnbucket-vectors/bin/pip install botocore alibabacloud-oss-v2 oss2
/tmp/ccinnbucket-vectors/bin/python -I scripts/vectors/generate_signing_vectors.py
```

The script rewrites `Tests/StorageSigningTests/Fixtures/*.json`. The SDKs are not project dependencies; keep them in a throwaway virtualenv.

### Trying the MCP server

```bash
swift build
.build/debug/CcinnBucket mcp --help
claude mcp add ccinnbucket-dev -- "$PWD/.build/debug/CcinnBucket" mcp
```

A debug build has a different code signature from the app that saved your Keychain items, so macOS asks once before it can read them.

### Running the app against a server directly

```bash
dist/CcinnBucket.app/Contents/MacOS/CcinnBucket \
  --connect http://127.0.0.1:19900 --kind minio \
  --access-key "$CCINNBUCKET_IT_ACCESS_KEY" --secret-key "$CCINNBUCKET_IT_SECRET_KEY" \
  --bucket demo --prefix photos/
```

These launch arguments are a development convenience: arguments are visible to other processes, so use them only with local test servers.

## Project layout

| Module | Responsibility |
|---|---|
| `StorageSigning` | AWS SigV4, OSS V4 and V1 signing and presigning (pure functions, no I/O) |
| `StorageKit` | Transport, retries and clock skew, S3/OSS dialects, bounded XML, operations, multipart/download/copy engines |
| `CcinnBucketKit` | UI-independent app logic: accounts and Keychain, credential import, navigation, transfer queue, MCP server and tools |
| `CcinnBucket` | SwiftUI/AppKit application (and the `mcp` subcommand entry point) |

Dependencies only point downwards; lower modules must not import higher ones.

## Guidelines

- **Test first.** Add or update tests with every behaviour change. Client behaviour is covered with the fake transport in `Tests/StorageKitTests/Support`, and server behaviour with the MinIO integration suite.
- **Never crash on input.** No force unwraps/casts, unchecked indexing or trapping integer conversions on data that comes from a server, a file or the user. Throw a descriptive error instead.
- **Bounded memory.** Responses, XML documents and part buffers have explicit limits; large bodies stream to disk.
- **Concurrency.** Code must compile in Swift 6 strict-concurrency mode. Keep shared mutable state inside actors or behind small, well-scoped locks; do not block the main actor with I/O or heavy formatting.
- **Provider differences** belong in the `ProviderDialect` types, not in scattered `if provider == …` checks.
- **Secrets** must never appear in logs, errors, audit records or files other than the Keychain.
- Keep pull requests focused, and update `CHANGELOG.md` under *Unreleased*.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/): `feat(scope): …`, `fix(scope): …`, `docs: …`, `test: …`, `refactor: …`, `chore: …`.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make sure `swift build` and `swift test --skip IntegrationTests` pass.
3. Describe what changed and how you tested it (including which storage services, if relevant).

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE). Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).
