#!/usr/bin/env python3
"""Signal every process in one row of the popup's list.

  kill_group.py NAME SIGNAL [PID...]     (SIGNAL: TERM or KILL)

Rows group by basename of argv[0] (apps.app_name), so the processes are looked
up again here instead of trusting a list that may be seconds old. With PIDs,
only those of the row's processes are signalled (an inner line of the popup).

A PID is only a number, and the kernel reuses it once its process is gone.
So each process is first held by a pidfd, then its name is read, then the
signal goes through that pidfd: it can reach only the process whose name was
checked. If that process ends in between, the signal reaches nothing.

Nothing is filtered by owner: the kernel decides what may be signalled. A
refused signal (EPERM) is reported with the owner of the process.

Prints: NAME \\t signalled \\t denied \\t owners-of-denied (space separated)
An empty NAME, a SIGNAL other than TERM/KILL or a PID that is not a number
signals nothing, prints nothing and exits 2. A system without pidfds
(Linux before 5.3, Python before 3.9) signals nothing and exits 3.
"""
import os
import pwd
import signal
import sys

from apps import app_name, status_kb

SIGNALS = {"TERM": signal.SIGTERM, "KILL": signal.SIGKILL}


def row_name(pid, proc="/proc"):
    """The row a process belongs to, or None (gone, a kernel thread, a zombie)."""
    try:
        with open(os.path.join(proc, str(pid), "cmdline"), "rb") as f:
            cmdline = f.read()
        with open(os.path.join(proc, str(pid), "status")) as f:
            status = f.read()
    except OSError:
        return None
    if not cmdline or status_kb(status, "VmRSS:") <= 0:
        return None
    return app_name(cmdline)


def owner(pid, proc="/proc"):
    try:
        uid = os.stat(os.path.join(proc, str(pid))).st_uid
    except OSError:
        return ""
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def signal_group(name, sig, only=None, proc="/proc"):
    """Returns (signalled, denied, owners of the denied)."""
    ok = denied = 0
    owners = []
    for entry in os.listdir(proc):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid == os.getpid() or (only is not None and pid not in only):
            continue
        try:
            fd = os.pidfd_open(pid)
        except OSError:
            continue  # gone already
        try:
            # Read after the pidfd is held: see the module text.
            if row_name(pid, proc) != name:
                continue
            signal.pidfd_send_signal(fd, sig)
            ok += 1
        except PermissionError:
            denied += 1
            who = owner(pid, proc)
            if who and who not in owners:
                owners.append(who)
        except ProcessLookupError:
            pass  # ended in between: nothing to report
        finally:
            os.close(fd)
    return ok, denied, owners


def main(argv):
    name = argv[0] if argv else ""
    sig = SIGNALS.get(argv[1] if len(argv) > 1 else "TERM")
    if not name or sig is None or not all(a.isdigit() for a in argv[2:]):
        print("kill_group.py: usage: NAME TERM|KILL [PID...]", file=sys.stderr)
        return 2
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        print("kill_group.py: this system has no pidfds, nothing was signalled", file=sys.stderr)
        return 3
    only = {int(a) for a in argv[2:]} if len(argv) > 2 else None
    ok, denied, owners = signal_group(name, sig, only)
    print("%s\t%d\t%d\t%s" % (name, ok, denied, " ".join(owners)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
