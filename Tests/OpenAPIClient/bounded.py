"""Run acceptance workloads with elapsed-time and aggregate descendant RSS limits."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def run(command, seconds, rss_kib, prefix):
    start = time.monotonic()
    peak = 0
    stopped = None
    prefix.parent.mkdir(parents=True, exist_ok=True)
    log_path = prefix.with_suffix(".log")
    with log_path.open("wb") as log:
        process = subprocess.Popen(
            command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
        )
        try:
            while process.poll() is None:
                listing = subprocess.check_output(
                    ["ps", "-axo", "pid=,ppid=,rss="], text=True
                )
                rows = {}
                for line in listing.splitlines():
                    pid, parent, rss = map(int, line.split())
                    rows[pid] = (parent, rss)
                owned = {process.pid}
                previous = set()
                while owned != previous:
                    previous = owned.copy()
                    owned.update(pid for pid, row in rows.items() if row[0] in owned)
                peak = max(peak, sum(rows[pid][1] for pid in owned if pid in rows))
                if time.monotonic() - start >= seconds:
                    stopped = f"{seconds:g} second limit"
                    break
                if peak > rss_kib:
                    stopped = f"{rss_kib} KiB aggregate RSS limit"
                    break
                time.sleep(0.25)
        finally:
            # The process owns a new session; never signal an unrelated process.
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
    metrics = {
        "command": command,
        "exit": process.returncode,
        "elapsed_seconds": round(time.monotonic() - start, 3),
        "peak_process_tree_rss_kib": peak,
        "stopped": stopped,
    }
    prefix.with_suffix(".metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    print(log_path.read_text(errors="replace"), end="")
    print(json.dumps(metrics, indent=2))
    return 124 if stopped else process.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--rss-kib", type=int, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.seconds <= 0 or args.rss_kib <= 0 or not command:
        parser.error("Positive limits and a command are required.")
    raise SystemExit(run(command, args.seconds, args.rss_kib, args.prefix))


if __name__ == "__main__":
    main()
