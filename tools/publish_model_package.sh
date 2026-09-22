#!/bin/bash
# Assemble a publishable pp model package from a converted MLX directory.
#
#   tools/publish_model_package.sh models/laya-mlx [output-dir]
#
# Produces dist/<package>/ containing manifest.json plus the weights, and a
# .tar.gz beside it. Upload that directory as-is: the app fetches
# <base-url>/manifest.json and then each file named in it, so the host must serve
# the files flat at the same paths.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:-models/laya-mlx}"
OUT_ROOT="${2:-dist}"
NAME="$(basename "$SOURCE")"
STAGE="$OUT_ROOT/$NAME"

if [[ ! -f "$SOURCE/model.safetensors" ]]; then
  echo "error: $SOURCE/model.safetensors not found. Run tools/convert_laya.py first." >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$SOURCE/model.safetensors" "$SOURCE/config.json" "$SOURCE/tokenizer.json" "$SOURCE/tokenizer_config.json" "$STAGE/"

# The manifest is generated from the staged files so its checksums describe exactly
# what ships, never a stale earlier conversion.
python3 Tools/make_manifest.py "$STAGE"

ARCHIVE="$OUT_ROOT/$NAME.tar.gz"
rm -f "$ARCHIVE"
tar -czf "$ARCHIVE" -C "$OUT_ROOT" "$NAME"
shasum -a 256 "$ARCHIVE" | tee "$ARCHIVE.sha256"

cat <<EOF

Package ready:  $STAGE
Archive:        $ARCHIVE

Publish the *contents* of $STAGE so these resolve:
  <base-url>/manifest.json
  <base-url>/model.safetensors
  <base-url>/config.json
  <base-url>/tokenizer.json
  <base-url>/tokenizer_config.json

Then point pp at it:
  defaults write local.pp ModelPackageBaseURL 'https://your.host/pp/laya-mlx'
or for one run:
  PP_MODEL_BASE_URL=https://your.host/pp/laya-mlx ./build.sh
EOF
