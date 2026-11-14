## Summary

<!-- What does this change and why? -->

## Testing

- [ ] `swift build` and `swift test --skip IntegrationTests` pass
- [ ] Integration tests run against MinIO (`scripts/storage-up.sh`) if the transport, signing, operations or MCP server changed
- [ ] Signing changes are covered by SDK-generated vectors (`scripts/vectors/generate_signing_vectors.py`), not hand-written signatures
- [ ] UI changes checked in light and dark appearance

## Notes

<!-- Providers affected (S3, S3-compatible, OSS), screenshots, follow-ups. Update CHANGELOG.md under "Unreleased". -->
