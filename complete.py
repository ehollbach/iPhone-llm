#!/usr/bin/env python3
"""Text completion on the device, typed on the Mac.

    ./complete.py -r . "The quick brown fox jumps over the lazy"    one completion, ends at the first "."
    ./complete.py                                                   REPL: one prompt per line, Ctrl-D to quit
    ./complete.py --chat -m qwen2.5-1.5b-instruct-q2_k.gguf "Hi"    a chat model instead of raw text

The model stays loaded for the whole session; each prompt is independent. Ctrl-C while it is
generating stops the run on the device. Connection settings are the same environment variables
as scripts/deploy.sh: DEVICE_HOST, DEVICE_PORT, DEVICE_USER, SSH_KEY, BIN_DIR, MODEL_DIR.
"""
import argparse
import json
import os
import queue
import shlex
import socket
import subprocess
import sys
import threading
import time

HOST = os.environ.get("DEVICE_HOST", "localhost")
PORT = int(os.environ.get("DEVICE_PORT", "2222"))
USER = os.environ.get("DEVICE_USER", "root")
KEY = os.path.expanduser(os.environ.get("SSH_KEY", "~/.ssh/id_ed25519"))
BIN_DIR = os.environ.get("BIN_DIR", "/usr/local/bin")
MODEL_DIR = os.environ.get("MODEL_DIR", "/var/mobile/llm")
MODEL = "Qwen2.5-1.5B.Q2_K.gguf"
SSH = ["ssh", "-i", KEY, "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-p", str(PORT), f"{USER}@{HOST}"]

DIM, BOLD, RESET = ("\033[2m", "\033[1m", "\033[0m") if sys.stdout.isatty() else ("", "", "")


def port_open() -> bool:
    try:
        with socket.create_connection((HOST, PORT), timeout=1):
            return True
    except OSError:
        return False


def ensure_tunnel():
    """Over USB, start `iproxy PORT:22` if nothing listens yet; return the process we started, if any."""
    if HOST not in ("localhost", "127.0.0.1") or port_open():
        return None
    try:
        proc = subprocess.Popen(["iproxy", f"{PORT}:22"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        sys.exit(f"nothing listens on {HOST}:{PORT} and iproxy is not installed (brew install libimobiledevice)")
    for _ in range(20):
        if port_open():
            return proc
        time.sleep(0.25)
    proc.terminate()
    sys.exit("could not start iproxy: is the device plugged in and unlocked?")


def stop_on_device():
    subprocess.run(SSH + ["killall systemone-cli 2>/dev/null"], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=15)


class Ticker:
    """Elapsed seconds on stderr while the device works."""

    def __init__(self, label):
        self.label, self.stop_evt = label, threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        t0 = time.monotonic()
        while not self.stop_evt.wait(1):
            sys.stderr.write(f"\r{DIM}{self.label} {time.monotonic() - t0:4.0f} s{RESET}")
            sys.stderr.flush()

    def __enter__(self):
        if sys.stderr.isatty():
            self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stop_evt.set()
        if self.thread.is_alive():
            self.thread.join()
            sys.stderr.write("\r\033[K")
            sys.stderr.flush()


def main():
    ap = argparse.ArgumentParser(description="Text completion on the device")
    ap.add_argument("prompt", nargs="*", help="complete once and exit; omit for the REPL")
    ap.add_argument("-m", "--model", default=MODEL, help=f"GGUF file in MODEL_DIR on the device (default {MODEL})")
    ap.add_argument("-r", "--reverse-prompt", action="append", default=[], metavar="STR",
                    help="stop when the model writes STR (repeatable)")
    ap.add_argument("-n", "--max-tokens", type=int, default=48, help="length cap (default 48)")
    ap.add_argument("--temperature", type=float, help="sampling temperature (default 0.8, 0 = greedy)")
    ap.add_argument("--chat", action="store_true", help="send the text as a chat message (instruct models)")
    ap.add_argument("-t", "--threads", type=int, default=2, help="CPU threads (default 2, one per core on a 2-core phone)")
    ap.add_argument("-c", "--ctx-size", type=int, default=512, help="context in tokens (default 512)")
    ap.add_argument("--repack", action="store_true",
                    help="keep a repacked copy of the weights: faster on ARM, about twice the RAM")
    args = ap.parse_args()

    if not os.path.exists(KEY):
        sys.exit(f"missing SSH key {KEY} (set SSH_KEY)")
    tunnel = ensure_tunnel()

    cli = shlex.quote(f"{BIN_DIR}/systemone-cli")
    repack = "" if args.repack else " --no-repack"
    remote = (f"cd {shlex.quote(MODEL_DIR)} && exec {cli} -m {shlex.quote(args.model)} "
              f"--chat{repack} -c {args.ctx_size} -t {args.threads} --time")  # --chat: text generation, raw prompts included
    proc = subprocess.Popen(SSH + [remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, bufsize=1)

    lines: "queue.Queue[str | None]" = queue.Queue()
    log: list[str] = []

    def pump_stderr():
        for line in proc.stderr:
            log.append(line)
            lines.put(line)
        lines.put(None)

    threading.Thread(target=pump_stderr, daemon=True).start()

    interrupted = False
    try:
        with Ticker("loading the model on the device…"):
            while True:
                line = lines.get()
                if line is None or "loaded for chat" in line:
                    break
        if line is None:
            sys.exit("the device did not load the model:\n" + "".join(log[-10:]))

        def run(text: str):
            if args.chat:
                req = {"messages": [{"role": "user", "content": text}]}
            else:
                req = {"prompt": text}
            req["max_tokens"] = args.max_tokens
            if args.reverse_prompt:
                req["stop"] = args.reverse_prompt
            if args.temperature is not None:
                req["temperature"] = args.temperature
            proc.stdin.write(json.dumps(req) + "\n")
            proc.stdin.flush()
            with Ticker("generating…"):
                out = proc.stdout.readline()
            if not out:
                sys.exit("the device closed the session:\n" + "".join(log[-10:]))
            r = json.loads(out)
            if "error" in r:
                print(f"error: {r['error']}")
                return
            if args.chat:
                print(r["message"]["content"].strip())
            else:
                print(f"{text}{BOLD}{r['text']}{r.get('stop_sequence', '')}{RESET}")
            u, t = r.get("usage", {}), r.get("timings", {})
            n_out, gen_s = u.get("output_tokens", 0), t.get("generation_ms", 0) / 1000
            per_tok = f", {gen_s / n_out:.1f} s/token" if n_out else ""
            note = " (hit the length cap, try -n)" if r.get("finish_reason") == "length" else ""
            print(f"{DIM}{u.get('input_tokens', 0)} prompt tokens in {t.get('prompt_ms', 0) / 1000:.1f} s · "
                  f"{n_out} tokens in {gen_s:.1f} s{per_tok}{note}{RESET}")

        if args.prompt:
            run(" ".join(args.prompt))
        else:
            mode = "chat" if args.chat else "raw completion"
            print(f"{args.model} · {mode} · up to {args.max_tokens} tokens · Ctrl-D to quit")
            while True:
                try:
                    line = input("\n› ")
                except EOFError:
                    print()
                    break
                if line.strip().lower() in ("quit", "exit", ":q"):
                    break
                if line.strip():
                    run(line.strip() if args.chat else line)  # a raw prompt keeps its trailing space
    except KeyboardInterrupt:
        interrupted = True
        print("\nstopping the run on the device…", file=sys.stderr)
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        if interrupted:
            proc.terminate()
            stop_on_device()
        else:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.terminate()
                stop_on_device()
        if tunnel:
            tunnel.terminate()


if __name__ == "__main__":
    main()
