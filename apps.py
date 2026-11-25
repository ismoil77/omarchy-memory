#!/usr/bin/env python3
"""Memory held by each program, for the Memory widget's popup.

Processes are grouped by the basename of argv[0], the same rule kill_group.py
and breakdown.sh use, so "Stop" acts on exactly the processes of a row.
Prints one JSON object, no human words:

  {"apps": [{"name", "rss", "swap", "count"}]}   kB, largest RSS first

  apps.py [TOP]      TOP rows (default 10, at most 50)

Reads /proc only; one run takes a few tens of milliseconds. Runs only while
the popup is open.
"""
import json
import os
import sys


def app_name(cmdline):
    """argv[0]'s basename, as `ps -o args` shows it: Chromium rewrites its argv
    into one space-separated string, so the first space ends the name too."""
    first = cmdline.split(b"\0", 1)[0].split(b" ", 1)[0]
    name = first.rsplit(b"/", 1)[-1].decode("utf-8", "replace")
    return name[:-1] if name.endswith(":") else name


def status_kb(text, key):
    i = text.find(key)
    if i < 0:
        return 0
    try:
        return int(text[i + len(key):].split(None, 1)[0])
    except (ValueError, IndexError):
        return 0


def collect(proc="/proc"):
    groups = {}
    for pid in os.listdir(proc):
        if not pid.isdigit():
            continue
        try:
            with open(os.path.join(proc, pid, "cmdline"), "rb") as f:
                cmdline = f.read()
            with open(os.path.join(proc, pid, "status")) as f:
                status = f.read()
        except OSError:
            continue  # gone, or not ours to read
        if not cmdline:
            continue  # kernel thread
        rss = status_kb(status, "VmRSS:")
        if rss <= 0:
            continue
        name = app_name(cmdline)
        g = groups.setdefault(name, {"name": name, "rss": 0, "swap": 0, "count": 0})
        g["rss"] += rss
        g["swap"] += status_kb(status, "VmSwap:")
        g["count"] += 1
    return sorted(groups.values(), key=lambda g: g["rss"], reverse=True)


def main(argv):
    try:
        top = max(1, min(50, int(argv[0]))) if argv else 10
    except ValueError:
        top = 10
    print(json.dumps({"apps": collect()[:top]}, ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv[1:])
