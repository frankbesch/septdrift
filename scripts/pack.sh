#!/bin/bash
# Pack the repo for another Mac: no .build, recordings, receipts, git, or docs.
# The archive always unpacks as ./septdrift, whatever this checkout is called.
# Prints the archive path and size.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$(basename "$PWD")"
OUT="${TMPDIR:-/tmp}/septdrift-$(date +%Y%m%d-%H%M).tgz"
tar --exclude='.build' --exclude='recordings' --exclude='receipts.jsonl' --exclude='.git' --exclude='.DS_Store' \
    --exclude='.claude' --exclude='docs' -s ",^${SRC},septdrift," -czf "$OUT" -C .. "$SRC"
echo "$OUT"; du -h "$OUT" | cut -f1
