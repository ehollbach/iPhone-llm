#!/usr/bin/env bash
# Downloads a GGUF model into models/ and checks its SHA-256.
#
#   scripts/fetch-model.sh                 the default: Qwen2.5-1.5B (base), Q2_K, 676 MB, Apache-2.0
#   scripts/fetch-model.sh URL SHA256      any other GGUF; Hugging Face shows the SHA-256 on the file's page
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
if [ $# -eq 0 ]; then
    url="https://huggingface.co/mradermacher/Qwen2.5-1.5B-GGUF/resolve/main/Qwen2.5-1.5B.Q2_K.gguf"
    sha256="63cf56e7f23e442f75f3c6fdad6bd5bbe0c45dd13c9e2c79e3a6accdefbf330d" # Hugging Face's LFS hash
elif [ $# -eq 2 ]; then
    url="$1"
    sha256="$2"
else
    echo "usage: $0 [URL SHA256]" >&2
    exit 2
fi
if ! [[ "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "SHA256 must be 64 lowercase hex characters" >&2
    exit 2
fi
name="$(basename "${url%%\?*}")"
case "$name" in
    *.gguf) ;;
    *) echo "the URL must end in a .gguf file name" >&2; exit 2 ;;
esac
dest="$here/models/$name"

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
echo "fetched $dest (SHA-256 matches)"
