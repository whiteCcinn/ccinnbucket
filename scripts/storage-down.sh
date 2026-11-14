#!/usr/bin/env bash
# Removes the integration-test containers started by storage-up.sh (only ccinnbucket-it-*).
set -euo pipefail
names="$(docker ps -a --format '{{.Names}}' | grep '^ccinnbucket-it-' || true)"
if [[ -n "$names" ]]; then
  echo "$names" | xargs docker rm -f >/dev/null
  echo "removed: $(echo "$names" | tr '\n' ' ')" >&2
else
  echo "no ccinnbucket-it-* containers" >&2
fi
