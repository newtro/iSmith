#!/usr/bin/env python3
"""P8 performance run: 40 tabs across 4 spaces in the Debug app ("iSmith Dev") on a scratch data
folder, with local fixture pages. Memory is the RSS of the app plus every WebKit process
(WebContent, Networking, GPU) macOS counts as the app's (its "responsible" process), summed from
`ps` at each stage of App/PerfHarness.swift. Space-switch times come from the harness.

Usage: make build && Tools/perf-run.py [scratch dir]

Never touches the installed iSmith or its data: the Debug app has its own bundle id, and
ISMITH_DATA_DIR points it at the scratch folder. The Brave import offer is suppressed (a fixture
Brave root that doesn't exist, plus the first-run marker), so no macOS prompt appears.
"""
import ctypes
import json
import os
import random
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Build/Products/Debug/iSmith.app")
SPACES = ["Contoso", "Fabrikam", "Personal", "Newtro Studios"]
TABS_PER_SPACE = 10

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


def page(n):
    """A page with some weight: a few thousand DOM nodes, ~20 MB of JS objects, a drawn canvas
    and a timer, roughly a light web app rather than a blank page."""
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>Fixture {n}</title>
<style>td{{padding:2px 6px;border-bottom:1px solid #ddd;font:12px -apple-system}}</style></head><body>
<h1>Fixture page {n}</h1><canvas id="c" width="900" height="500"></canvas><table id="t"></table>
<script>
const rows = [];
for (let i = 0; i < 200000; i++) rows.push({{id: i, name: "row " + i, value: Math.random(), tags: ["a" + (i % 50), "b"]}});
window.keep = rows;
const t = document.getElementById("t");
for (let i = 0; i < 1500; i++) {{ const r = t.insertRow(); for (let j = 0; j < 4; j++) r.insertCell().textContent = rows[i * 7 + j].name; }}
const ctx = document.getElementById("c").getContext("2d");
for (let i = 0; i < 2000; i++) {{ ctx.fillStyle = `hsl(${{i % 360}},60%,60%)`; ctx.fillRect(Math.random()*900, Math.random()*500, 20, 20); }}
setInterval(() => {{ document.title = "Fixture {n}"; }}, 5000);
</script></body></html>"""


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def memory(app_pid):
    """(app RSS MB, WebKit RSS MB, total footprint MB, WebKit process counts) for the app and
    its WebKit processes."""
    out = subprocess.run(["ps", "-axo", "pid=,rss=,comm="], capture_output=True, text=True).stdout
    app = 0
    webkit = 0
    foot = 0
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


def main():
    scratch = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="ismith-perf-")
    data = os.path.join(scratch, "data")
    site = os.path.join(scratch, "site")
    os.makedirs(data, exist_ok=True)
    os.makedirs(site, exist_ok=True)
    for n in range(len(SPACES) * TABS_PER_SPACE):
        with open(os.path.join(site, f"p{n}.html"), "w") as f:
            f.write(page(n))
    port = free_port()
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"], cwd=site,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Four spaces with ten tabs each; the first two tabs of Contoso and Fabrikam are kept
    # alive (Outlook and Teams in real use).
    # A rerun on the same folder reuses its spaces' WebKit stores rather than leaving more behind.
    config_path = os.path.join(data, "config.json")
    stores = {}
    if os.path.exists(config_path):
        with open(config_path) as f:
            stores = {s["id"]: s["storeID"] for s in json.load(f).get("spaces", [])}
    spaces, records = [], []
    for i, name in enumerate(SPACES):
        sid = "perf-" + name.lower().replace(" ", "-")
        store = stores.get(sid) or str(uuid.uuid4()).upper()
        spaces.append({"id": sid, "name": name, "color": i, "storeID": store, "bindings": {}, "home": ""})
        tabs = []
        for j in range(TABS_PER_SPACE):
            n = i * TABS_PER_SPACE + j
            tabs.append({"id": str(uuid.uuid4()).upper(), "url": f"http://127.0.0.1:{port}/p{n}.html",
                         "title": f"Fixture {n}", "keepAlive": True if (i < 2 and j < 2) else None})
        records.append({"space": sid, "selected": tabs[0]["id"], "groups": [], "tabs": tabs})
    with open(os.path.join(data, "config.json"), "w") as f:
        json.dump({"version": 2, "providers": [], "accounts": [], "shared": {}, "spaces": spaces}, f)
    with open(os.path.join(data, "session.json"), "w") as f:
        json.dump({"version": 2, "windows": [{"id": str(uuid.uuid4()).upper(), "frame": None,
                                              "activeSpace": spaces[0]["id"], "spaces": records}]}, f)
    open(os.path.join(data, "brave-import-offered"), "w").close()
    stage_file = os.path.join(scratch, "stage")
    if os.path.exists(stage_file):
        os.remove(stage_file)

    subprocess.run(["open", "-n", "-a", APP, "--env", f"ISMITH_DATA_DIR={data}", "--env", f"ISMITH_PERF_STAGE_FILE={stage_file}",
                    "--env", f"ISMITH_BRAVE_ROOT={os.path.join(scratch, 'no-brave')}"], check=True)
    seen = None
    samples = {}
    started = time.time()
    try:
        while time.time() - started < 900:
            time.sleep(1)
            if not os.path.exists(stage_file):
                continue
            name, pid = open(stage_file).read().split()
            pid = int(pid)
            if name == "done":
                break
            if name != seen:
                seen = name
                time.sleep(4)  # let processes that are going away go
                taken = [memory(pid) for _ in range(3) if time.sleep(1) is None]
                app, webkit, foot, kinds = max(taken, key=lambda m: m[0] + m[1])
                samples[name] = {"appMB": round(app), "webkitMB": round(webkit), "totalMB": round(app + webkit),
                                 "footprintMB": round(foot), "processes": kinds}
                print(f"{name:12} RSS: app {app:6.0f} MB + WebKit {webkit:6.0f} MB = {app + webkit:6.0f} MB;"
                      f" footprint {foot:6.0f} MB  {kinds}", flush=True)
        for _ in range(30):
            if os.path.exists(stage_file + ".json"):
                break
            time.sleep(1)
        with open(stage_file + ".json") as f:
            harness = json.load(f)
        print(json.dumps({"memory": samples, "harness": harness}, indent=2, sort_keys=True))
    finally:
        server.terminate()


if __name__ == "__main__":
    main()
