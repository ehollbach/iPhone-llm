# iphone-llm

Text completion with a small language model on an iPhone, CPU only. You type on the Mac; the
phone does the work. It is built for the oldest arm64 iPhones first: the default setup runs
Qwen2.5-1.5B, 2-bit quantized, on an A7 with 1 GB of RAM and iOS 12.

```
$ ./complete.py -r . "The quick brown fox jumps over the lazy "
The quick brown fox jumps over the lazy 15 is the answer to the problem.
9 prompt tokens in 7.5 s · 9 tokens in 56.7 s, 6.3 s/token
```

(The odd ending comes from the trailing space in that prompt, see [Gotchas](#gotchas).)

> **Tested hardware.** The most recent hardware this has been tested on is an A7: an iPhone 5s
> running iOS 12.5.8. Newer iPhones and other iOS versions may well work, but nothing else has
> been tried. Your mileage may vary. No warranty, see [LICENSE](LICENSE).

## Requirements

- **A Mac with Xcode** (for the iPhoneOS SDK) and cmake.
- **A [kneejerk](https://github.com/moudrkat/kneejerk) checkout** with its chat mode and raw
  prompts (`{"prompt": ..., "stop": ...}`), with submodules. It provides `systemone-cli`, a
  small command-line front end to llama.cpp. Until that lands upstream, use the `chat-mode`
  branch of [ehollbach/kneejerk](https://github.com/ehollbach/kneejerk/tree/chat-mode):
  ```bash
  git clone --recursive --shallow-submodules -b chat-mode https://github.com/ehollbach/kneejerk.git
  ```
- **An arm64 iPhone that can run your own command-line binaries, reachable over SSH.** A stock
  iPhone cannot do this; getting a device into that state is outside the scope of this project.
  Over USB, `iproxy 2222:22` from libimobiledevice (`brew install libimobiledevice`) forwards SSH,
  and the scripts default to that.
- **Free space on the device** for the model: 676 MB for the default one.

## Quick start

```bash
KNEEJERK_DIR=~/src/kneejerk scripts/build.sh    # cross-compiles systemone-cli into build/bin
scripts/fetch-model.sh                           # 676 MB from Hugging Face, SHA-256 checked
iproxy 2222:22 &                                 # SSH over USB
SSH_KEY=~/.ssh/my_device_key scripts/deploy.sh   # copies both, retries, checks sizes
SSH_KEY=~/.ssh/my_device_key ./complete.py -r . "The quick brown fox jumps over the lazy"
```

`complete.py` with no prompt opens a REPL: one prompt per line, Ctrl-D to quit. `-r` is the
reverse prompt (stop string, repeatable), `-n` caps the length (default 48 tokens),
`--temperature 0` makes runs repeatable, and `--chat` sends the text as a chat message for
instruct models. Ctrl-C stops the run on the device as well.

Connection settings, shared by `deploy.sh` and `complete.py`:

| variable | default | |
|---|---|---|
| `DEVICE_HOST` | `localhost` | `iproxy` starts by itself for localhost |
| `DEVICE_PORT` | `2222` | |
| `DEVICE_USER` | `root` | |
| `SSH_KEY` | `~/.ssh/id_ed25519` | |
| `BIN_DIR` | `/usr/local/bin` | a directory the device lets you execute from |
| `MODEL_DIR` | `/var/mobile/llm` | the data partition, where the space is |

## Other models

Any GGUF that llama.cpp reads works the same way. Hugging Face shows a file's SHA-256 on its page:

```bash
scripts/fetch-model.sh https://huggingface.co/<repo>/resolve/main/<file>.gguf <sha256>
scripts/deploy.sh <file>.gguf
./complete.py -m <file>.gguf -r . "Once upon a time"
```

Use `--chat` for instruct models (the chat template comes from the GGUF) and leave it off for
base models. On a 1 GB phone, keep the file well under 1 GB; smaller is faster.

## Newer iPhones

The defaults are the safe baseline for the oldest hardware. On a newer phone (untested):

| setting | default | on a newer phone |
|---|---|---|
| `complete.py -t` | `2` | the number of performance cores |
| `complete.py --repack` | off | on, if RAM allows: faster on ARM, twice the memory |
| `complete.py -c` | `512` | larger, for longer prompts |
| `CPU_ARCH` (build) | `armv8-a` | the chip's instruction set, e.g. `armv8.2-a+fp16` |
| `IOS_DEPLOYMENT_TARGET` (build) | `12.0` | the device's iOS version |

## Measured

iPhone 5s (A7, 2 cores, 1 GB RAM), iOS 12.5.8, `--no-repack -c 512 -t 2`, 9 November 2026:

| model | prompt | generation |
|---|---|---|
| Qwen2.5-1.5B (base), Q2_K, 676 MB | 9 tokens in 7.5 s | 9 tokens in 56.7 s, 6.3 s/token |
| Qwen2.5-1.5B-Instruct, Q2_K, 753 MB, `--chat` | 41 tokens in 18.6 s | 19 tokens in 134 s, 7.1 s/token |

Slow, but it runs. The likely bottleneck is memory, not the CPU: the model barely fits in RAM
next to iOS, so pages of weights are probably re-read from flash for every token. That has not
been measured yet; a smaller model (0.5B) would tell. Numbers from other iPhones are welcome.

## How it fits

- **CPU only, ARMv8.0 by default.** The A7 has no dot-product or fp16 instructions, so ggml is
  built for plain `armv8-a`, which every arm64 iPhone runs. No Metal, and no Accelerate (ggml asks
  it for headers from iOS 16.4).
- **iOS 12's libc++ has no `std::filesystem`.** ggml links it for its dynamic backend loader,
  which never runs when the CPU backend is built in. kneejerk weak-links libc++ for deployment
  targets below iOS 13, so those unresolved symbols do not stop the binary at launch.
- **Half the RAM.** `--no-repack` (the default here) keeps one memory-mapped copy of the weights
  instead of a second, repacked one; `-c 512` keeps the KV cache small; `-t 2` matches two cores.

## Gotchas

- **A prompt that ends in a space.** Qwen's tokenizer attaches a word's leading space to the word:
  ` dog` is one token. A prompt ending in `"lazy "` leaves only tokens without a leading space,
  `dog` among them, and base models rarely continue that way, hence the `15` above. Leave the
  space out, `"... over the lazy"`.
- **Each prompt is independent.** No history is kept between prompts; reading the prompt costs
  roughly half a second per token on an A7.
- **The USB link can drop** during a large copy. `deploy.sh` retries and compares sizes.

## Model and licenses

- **Default model:** [Qwen2.5-1.5B](https://huggingface.co/Qwen/Qwen2.5-1.5B) by the Qwen team, Apache-2.0.
- **Quantization:** GGUF Q2_K by [mradermacher](https://huggingface.co/mradermacher/Qwen2.5-1.5B-GGUF),
  Apache-2.0. `fetch-model.sh` downloads it from Hugging Face and checks the SHA-256 pinned in the
  script; no weights are part of this repository. Other models come with their own licenses.
- **Inference:** [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) through
  [kneejerk](https://github.com/moudrkat/kneejerk) (MIT).
- **This repository:** MIT, see [LICENSE](LICENSE).
