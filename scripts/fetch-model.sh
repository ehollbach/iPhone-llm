#!/usr/bin/env bash
# Downloads the base model (Qwen2.5-1.5B, Q2_K GGUF, Apache-2.0) into models/ and checks its SHA-256.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
url="https://huggingface.co/mradermacher/Qwen2.5-1.5B-GGUF/resolve/main/Qwen2.5-1.5B.Q2_K.gguf"
sha256="63cf56e7f23e442f75f3c6fdad6bd5bbe0c45dd13c9e2c79e3a6accdefbf330d" # Hugging Face's LFS hash
dest="$here/models/Qwen2.5-1.5B.Q2_K.gguf"

mkdir -p "$here/models"
if [ -f "$dest" ] && echo "$sha256  $dest" | shasum -a 256 -c --status; then
    echo "$dest is already there and matches"
    exit 0
fi

curl -fL --retry 3 -o "$dest.part" "$url"
if ! echo "$sha256  $dest.part" | shasum -a 256 -c --status; then
    echo "checksum mismatch, the download was removed" >&2
    rm -f "$dest.part"
    exit 1
fi
mv "$dest.part" "$dest"
echo "fetched $dest (676 MB, SHA-256 matches)"
