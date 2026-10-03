#!/usr/bin/env python3
"""How much memory iSmith uses: the app plus every WebKit process (WebContent, Networking, GPU)
macOS counts as the app's ("responsible" process). Activity Monitor lists WebKit processes
separately and mixes in other apps' (Mail, Safari), so this sums only iSmith's.

Usage: Tools/memory.py            the running /Applications/iSmith.app
       Tools/memory.py <pid>      any running copy (e.g. "iSmith Dev")

Read-only: it only reads `ps` and each process's resource usage.
"""
import ctypes
import subprocess
import sys

libc = ctypes.CDLL(None)
responsible = libc.responsibility_get_pid_responsible_for_pid
responsible.restype = ctypes.c_int
responsible.argtypes = [ctypes.c_int]


class RUsage(ctypes.Structure):
    """rusage_info_v0: phys_footprint is what Activity Monitor shows as a process's Memory."""
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64),
                ("pkg_idle_wkups", ctypes.c_uint64), ("interrupt_wkups", ctypes.c_uint64), ("pageins", ctypes.c_uint64),
                ("wired_size", ctypes.c_uint64), ("resident_size", ctypes.c_uint64), ("phys_footprint", ctypes.c_uint64),
                ("start", ctypes.c_uint64), ("exit", ctypes.c_uint64), ("pad", ctypes.c_uint64 * 64)]


def footprint(pid):
    usage = RUsage()
    return usage.phys_footprint if libc.proc_pid_rusage(pid, 0, ctypes.byref(usage)) == 0 else 0


def memory(app_pid):
    """(app RSS MB, WebKit RSS MB, total footprint MB, WebKit process counts)."""
    out = subprocess.run(["ps", "-axo", "pid=,rss=,comm="], capture_output=True, text=True).stdout
    app = webkit = foot = 0
    kinds = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid, rss, comm = int(parts[0]), int(parts[1]), parts[2]
        if pid == app_pid:
            app += rss
            foot += footprint(pid)
        elif "com.apple.WebKit." in comm and responsible(pid) == app_pid:
            webkit += rss
            foot += footprint(pid)
            kind = comm.rsplit("com.apple.WebKit.", 1)[1]
            kinds[kind] = kinds.get(kind, 0) + 1
    return app / 1024, webkit / 1024, foot / 1048576, kinds


def installed_pid():
    out = subprocess.run(["pgrep", "-f", "^/Applications/iSmith.app/Contents/MacOS/iSmith"], capture_output=True, text=True).stdout
    pids = [int(p) for p in out.split()]
    return pids[0] if pids else None


def main():
    pid = int(sys.argv[1]) if len(sys.argv) > 1 else installed_pid()
    if pid is None:
        sys.exit("iSmith isn't running.")
    app, webkit, foot, kinds = memory(pid)
    print(f"iSmith (pid {pid}): {foot:,.0f} MB (Activity Monitor's Memory, summed); "
          f"RSS {app:,.0f} MB app + {webkit:,.0f} MB WebKit = {app + webkit:,.0f} MB; processes {kinds}")


if __name__ == "__main__":
    main()
