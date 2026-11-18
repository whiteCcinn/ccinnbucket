#!/usr/bin/env bash
# Regenerates Tests/DecompressionTests/Fixtures: deterministic plaintexts compressed with the real gzip and zstd CLIs,
# plus manifest.json (file, format, decoded size and SHA-256). Requires python3, gzip and zstd.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/Tests/DecompressionTests/Fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
command -v zstd >/dev/null || { echo "zstd is required" >&2; exit 1; }

python3 -I - "$WORK" <<'PY'
import json, os, random, sys
work = sys.argv[1]
rnd = random.Random(20261119)
words = ["auction", "bid", "imp", "win", "loss", "timeout", "dsp", "ssp", "geo", "MY", "SG", "banner", "video", "native"]
with open(os.path.join(work, "text.txt"), "w") as f:
    i = 0
    while f.tell() < 150 * 1024:
        f.write("%06d %s %s %s price=%.2f\n" % (i, rnd.choice(words), rnd.choice(words), rnd.choice(words), rnd.random() * 9))
        i += 1
with open(os.path.join(work, "random.bin"), "wb") as f:
    f.write(bytes(rnd.getrandbits(8) for _ in range(16 * 1024)))
with open(os.path.join(work, "runs.bin"), "wb") as f:
    f.write(b"a" * 150000 + b"b" * 150000 + b"abc" * 1000)
with open(os.path.join(work, "small.txt"), "w") as f:
    f.write("hello, zstd\n")
records = [{"id": i, "geo": rnd.choice(["MY", "SG", "ID"]), "price": round(rnd.random() * 3, 3)} for i in range(1500)]
with open(os.path.join(work, "data.json"), "w") as f:
    json.dump({"records": records}, f, indent=1)
PY

rm -f "$OUT"/*.zst "$OUT"/*.gz "$OUT"/manifest.json
mkdir -p "$OUT"
cd "$WORK"
zstd -q -1 -c text.txt > "$OUT/text-l1.zst"
zstd -q -3 -c text.txt > "$OUT/text-l3.zst"
zstd -q -19 -c text.txt > "$OUT/text-l19.zst"
zstd -q -3 --no-check -c text.txt > "$OUT/text-l3-nocheck.zst"
cat text.txt | zstd -q -19 --long=24 -c > "$OUT/text-long24-stdin.zst"
zstd -q -3 -c random.bin > "$OUT/random.zst"
zstd -q -3 -c runs.bin > "$OUT/runs.zst"
zstd -q -3 -c small.txt > "$OUT/small.zst"
zstd -q -19 -c data.json > "$OUT/data-l19.zst"
# Two frames with a skippable frame (magic 0x184D2A5A, 8 bytes of payload) between them.
{ cat "$OUT/small.zst"; printf '\x5a\x2a\x4d\x18\x08\x00\x00\x00skipme!!'; zstd -q -3 -c data.json; } > "$OUT/frames.zst"
gzip -1 -c text.txt > "$OUT/text-1-named.gz"
gzip -9 -n -c text.txt > "$OUT/text-9.gz"
gzip -6 -n -c random.bin > "$OUT/random.gz"
{ gzip -n -c small.txt; gzip -9 -n -c data.json; } > "$OUT/multi.gz"
cat small.txt data.json > small-data.json

python3 -I - "$OUT" "$WORK" <<'PY'
import hashlib, json, os, sys
out, work = sys.argv[1], sys.argv[2]
sources = {
    "text-l1.zst": "text.txt", "text-l3.zst": "text.txt", "text-l19.zst": "text.txt", "text-l3-nocheck.zst": "text.txt",
    "text-long24-stdin.zst": "text.txt", "random.zst": "random.bin", "runs.zst": "runs.bin", "small.zst": "small.txt",
    "data-l19.zst": "data.json", "frames.zst": "small-data.json", "text-1-named.gz": "text.txt", "text-9.gz": "text.txt",
    "random.gz": "random.bin", "multi.gz": "small-data.json",
}
manifest = []
for name in sorted(sources):
    data = open(os.path.join(work, sources[name]), "rb").read()
    manifest.append({"file": name, "format": "zstd" if name.endswith(".zst") else "gzip", "size": len(data),
                     "sha256": hashlib.sha256(data).hexdigest()})
with open(os.path.join(out, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
du -sh "$OUT"
