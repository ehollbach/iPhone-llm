#!/usr/bin/env bash
# Copies build/bin/systemone-cli and models/*.gguf to the device over SSH, then checks the sizes.
#
#   DEVICE_HOST  (localhost)       with iproxy from libimobiledevice: `iproxy 2222:22` forwards over USB
#   DEVICE_PORT  (2222)
#   DEVICE_USER  (root)
#   SSH_KEY      (~/.ssh/id_ed25519)
#   BIN_DIR      (/usr/local/bin)  a directory the device lets you execute from
#   MODEL_DIR    (/var/mobile/llm) the data partition, where the space is
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
host="${DEVICE_HOST:-localhost}"
port="${DEVICE_PORT:-2222}"
user="${DEVICE_USER:-root}"
key="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
bin_dir="${BIN_DIR:-/usr/local/bin}"
model_dir="${MODEL_DIR:-/var/mobile/llm}"

bin="$here/build/bin/systemone-cli"
[ -f "$bin" ] || { echo "no $bin: run scripts/build.sh first" >&2; exit 1; }
shopt -s nullglob
models=("$here"/models/*.gguf)
[ ${#models[@]} -gt 0 ] || { echo "no models/*.gguf: run scripts/fetch-model.sh first" >&2; exit 1; }

ssh_opts=(-i "$key" -o BatchMode=yes -o ServerAliveInterval=5)
remote() { ssh "${ssh_opts[@]}" -p "$port" "$user@$host" "$@"; }

# a USB link can drop in the middle of a large copy: scp leaves a short file, so retry and compare sizes
copy() {
    local src="$1" dst="$2" size remote_size
    size=$(stat -f %z "$src")
    for attempt in 1 2 3; do
        if scp "${ssh_opts[@]}" -P "$port" "$src" "$user@$host:$dst"; then
            remote_size=$(remote "wc -c < '$dst'" | tr -d ' ')
            [ "$remote_size" = "$size" ] && { echo "copied $(basename "$src") ($size bytes)"; return 0; }
        fi
        echo "copy of $(basename "$src") failed (attempt $attempt), retrying" >&2
        sleep 3
    done
    echo "could not copy $src" >&2
    return 1
}

remote "mkdir -p '$bin_dir' '$model_dir'"
copy "$bin" "$bin_dir/systemone-cli.new"
remote "chmod 755 '$bin_dir/systemone-cli.new' && mv '$bin_dir/systemone-cli.new' '$bin_dir/systemone-cli' && '$bin_dir/systemone-cli' -h >/dev/null 2>&1" \
    || { echo "the device would not run $bin_dir/systemone-cli (see README, Requirements)" >&2; exit 1; }
for m in "${models[@]}"; do
    copy "$m" "$model_dir/$(basename "$m")"
done
echo "done: $bin_dir/systemone-cli, models in $model_dir"
