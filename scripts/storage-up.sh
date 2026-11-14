#!/usr/bin/env bash
# Starts a local MinIO server for CcinnBucket's integration tests and seeds demo data.
#
#   eval "$(scripts/storage-up.sh)"      # start (or reuse) and export CCINNBUCKET_IT_* variables
#   swift test --filter IntegrationTests
#   scripts/storage-down.sh
#
# Containers are named ccinnbucket-it-* and only bind 127.0.0.1 ports 19900-19919.
# Seeded buckets:
#   ccinn-demo       nested prefixes, previews (text/JSON/Markdown/PDF/PNG/log), unicode and special keys,
#                    folder markers, and one incomplete multipart upload
#   ccinn-large      50,000 objects under bulk/ (paging and virtualisation) plus 2,000 under sharded/
#   ccinn-versioned  versioning enabled: several versions and a delete marker
# Compatible with the bash 3.2 that ships with macOS.
set -euo pipefail

IMAGE="bitnamilegacy/minio:2025.7.23-debian-12-r5" # upstream MinIO RELEASE.2025-07-23T15-54-02Z
NAME="ccinnbucket-it-minio"
API_PORT=19900
CONSOLE_PORT=19901
ACCESS_KEY="ccinnbucket"
SECRET_KEY="ccinnbucket-local-secret"
REGION="us-east-1"
ENDPOINT="http://127.0.0.1:${API_PORT}"
BULK_COUNT="${CCINNBUCKET_BULK_COUNT:-50000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { echo "$*" >&2; }

if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  log "starting $NAME ($IMAGE) on 127.0.0.1:${API_PORT}"
  docker run -d --name "$NAME" \
    --cpus 2 --memory 1g \
    -p "127.0.0.1:${API_PORT}:9000" -p "127.0.0.1:${CONSOLE_PORT}:9001" \
    -e MINIO_ROOT_USER="$ACCESS_KEY" -e MINIO_ROOT_PASSWORD="$SECRET_KEY" \
    -e MINIO_REGION="$REGION" -e MINIO_BROWSER=on \
    "$IMAGE" >/dev/null
fi

ready=false
for _ in $(seq 1 90); do
  if curl -fsS "${ENDPOINT}/minio/health/ready" >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  log "MinIO did not become ready; see: docker logs $NAME"
  exit 1
fi

mcx() { docker exec "$NAME" mc --quiet "$@"; }
docker exec "$NAME" mc alias set local http://127.0.0.1:9000 "$ACCESS_KEY" "$SECRET_KEY" >/dev/null

seeded="$(docker exec "$NAME" sh -c 'test -f /tmp/.ccinnbucket-seeded && cat /tmp/.ccinnbucket-seeded || true')"
if [[ "$seeded" != "v1-${BULK_COUNT}" ]]; then
  log "seeding demo data (this takes a minute the first time)…"
  for bucket in ccinn-demo ccinn-large ccinn-versioned; do mcx mb --ignore-existing "local/${bucket}" >/dev/null; done

  # ccinn-demo: a realistic tree with previewable files and awkward keys.
  docker exec "$NAME" sh -c '
    set -e
    rm -rf /tmp/demo && mkdir -p /tmp/demo && cd /tmp/demo
    mkdir -p photos/2024/january photos/2024/june photos/2025/march docs data logs "unicode/日本語 フォルダ" special site/css site/js
    for month in january june; do
      i=1; while [ $i -le 24 ]; do head -c $((20000 + i * 997)) /dev/urandom > "photos/2024/$month/IMG_2024$(printf %04d $i).jpg"; i=$((i+1)); done
    done
    i=1; while [ $i -le 8 ]; do head -c $((150000 + i * 4099)) /dev/urandom > "photos/2025/march/DSC_$(printf %05d $i).raw"; i=$((i+1)); done
    printf "# CcinnBucket demo\n\nThis bucket was seeded by \`scripts/storage-up.sh\`.\n\n- Nested prefixes\n- Unicode keys\n- Previews\n" > docs/README.md
    printf "{\"name\":\"ccinnbucket\",\"version\":\"1.0.0\",\"features\":[\"s3\",\"oss\",\"multipart\",\"presign\"],\"limits\":{\"parts\":10000,\"partSizeMiB\":[5,5120]},\"enabled\":true}\n" > data/config.json
    i=0; while [ $i -lt 400 ]; do printf "{\"id\":%d,\"event\":\"upload\",\"bytes\":%d}\n" $i $((i * 7919 % 100000)) ; i=$((i+1)); done > data/events.ndjson
    printf "id,name,size\n1,alpha,10\n2,beta,20\n3,gamma,30\n" > data/table.csv
    yes "2026-11-14T08:30:15Z INFO  transfer worker=3 part=17 bytes=8388608 status=ok latency_ms=142" | head -c 3145728 > logs/app-2026-11-14.log
    printf "%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 420 300]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n4 0 obj<</Length 88>>stream\nBT /F1 28 Tf 40 200 Td (CcinnBucket) Tj ET BT /F1 14 Tf 40 160 Td (Quarterly storage report) Tj ET\nendstream endobj\n5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n" > docs/report.pdf
    printf "<!doctype html><title>Demo</title><h1>Hello from CcinnBucket</h1>\n" > site/index.html
    printf "body { font-family: system-ui; color: #0b4f6c; }\n" > site/css/app.css
    printf "console.log(\"hello\");\n" > site/js/app.js
    printf "日本語のテキスト\n" > "unicode/日本語 フォルダ/メモ.txt"
    printf "naïve café\n" > "unicode/naïve café ✓.txt"
    printf "emoji\n" > "unicode/🪣 bucket.txt"
    printf "plus and tilde\n" > "special/a+b c~d.txt"
    printf "percent\n" > "special/100% sure & ready (v2).txt"
    printf "punctuation\n" > "special/semi;colon,comma=equals@at#hash.txt"
    printf "quotes\n" > "special/it'"'"'s \"quoted\".txt"
  '
  mcx mirror --overwrite /tmp/demo local/ccinn-demo >/dev/null
  # Folder markers (zero-byte keys ending in "/"), including an empty folder. mc refuses such names, so use curl.
  for marker in empty-folder/ photos/; do
    curl -fsS -X PUT --aws-sigv4 "aws:amz:${REGION}:s3" --user "${ACCESS_KEY}:${SECRET_KEY}" \
      -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" --data-binary "" "${ENDPOINT}/ccinn-demo/${marker}" >/dev/null
  done
  if [[ -f "$ROOT/scripts/fixtures/sample.png" ]]; then
    docker cp "$ROOT/scripts/fixtures/sample.png" "$NAME:/tmp/sample.png" >/dev/null
    mcx cp --attr "Content-Type=image/png" /tmp/sample.png local/ccinn-demo/photos/cover.png >/dev/null
  fi
  mcx cp --attr "Content-Type=application/json;Cache-Control=max-age=60;x-amz-meta-owner=ccinn;x-amz-meta-team=storage" \
    /tmp/demo/data/config.json local/ccinn-demo/data/config.json >/dev/null
  mcx tag set local/ccinn-demo/data/config.json "env=demo&tier=hot" >/dev/null

  # ccinn-large: one flat prefix with BULK_COUNT objects, plus sharded sub-prefixes.
  docker exec -e BULK_COUNT="$BULK_COUNT" "$NAME" sh -c '
    set -e
    rm -rf /tmp/large && mkdir -p /tmp/large/bulk && cd /tmp/large/bulk
    i=0; while [ $i -lt "$BULK_COUNT" ]; do printf "object %d\n" $i > "obj-$(printf %06d $i).txt"; i=$((i+1)); done
    cd /tmp/large && s=0; while [ $s -lt 20 ]; do mkdir -p "sharded/shard-$(printf %02d $s)"; j=0; while [ $j -lt 100 ]; do printf "%d-%d\n" $s $j > "sharded/shard-$(printf %02d $s)/item-$(printf %03d $j).txt"; j=$((j+1)); done; s=$((s+1)); done
  '
  mcx mirror --overwrite /tmp/large local/ccinn-large >/dev/null
  docker exec "$NAME" rm -rf /tmp/large /tmp/demo

  # ccinn-versioned: versions and a delete marker.
  mcx version enable local/ccinn-versioned >/dev/null
  for n in 1 2 3; do
    docker exec "$NAME" sh -c "printf '{\"revision\": $n}\n' | mc --quiet pipe local/ccinn-versioned/config.json >/dev/null"
  done
  docker exec "$NAME" sh -c "printf 'draft\n' | mc --quiet pipe local/ccinn-versioned/notes/draft.txt >/dev/null"
  docker exec "$NAME" sh -c "printf 'final\n' | mc --quiet pipe local/ccinn-versioned/notes/draft.txt >/dev/null"
  mcx rm local/ccinn-versioned/notes/draft.txt >/dev/null
  docker exec "$NAME" sh -c "printf 'kept\n' | mc --quiet pipe local/ccinn-versioned/readme.txt >/dev/null"

  docker exec "$NAME" sh -c "echo v1-${BULK_COUNT} > /tmp/.ccinnbucket-seeded"
fi

# One incomplete multipart upload for the "Incomplete uploads" view (idempotent: only if none exist).
if ! curl -fsS --aws-sigv4 "aws:amz:${REGION}:s3" --user "${ACCESS_KEY}:${SECRET_KEY}" \
    "${ENDPOINT}/ccinn-demo?uploads" 2>/dev/null | grep -q "<UploadId>"; then
  curl -fsS -X POST --aws-sigv4 "aws:amz:${REGION}:s3" --user "${ACCESS_KEY}:${SECRET_KEY}" \
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" "${ENDPOINT}/ccinn-demo/videos/unfinished-upload.mov?uploads" >/dev/null
fi

log "MinIO ready at ${ENDPOINT} (console http://127.0.0.1:${CONSOLE_PORT}, user ${ACCESS_KEY})"
echo "export CCINNBUCKET_IT=1"
echo "export CCINNBUCKET_IT_ENDPOINT=${ENDPOINT}"
echo "export CCINNBUCKET_IT_ACCESS_KEY=${ACCESS_KEY}"
echo "export CCINNBUCKET_IT_SECRET_KEY=${SECRET_KEY}"
echo "export CCINNBUCKET_IT_REGION=${REGION}"
echo "export CCINNBUCKET_IT_BULK_COUNT=${BULK_COUNT}"
