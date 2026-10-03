#!/usr/bin/env python3
"""P8 performance run: 40 tabs across 4 spaces in the Debug app ("iSmith Dev") on a scratch data
folder, with local fixture pages. Memory is the RSS of the app plus every WebKit process
(WebContent, Networking, GPU) macOS counts as the app's (its "responsible" process), summed from
`ps` at each stage of App/PerfHarness.swift, with the summed footprint alongside (see
Tools/memory.py). Space-switch times come from the harness.

Usage: make build && Tools/perf-run.py [--keep] [scratch dir]
  --keep  leave the run's WebKit stores (in the Debug app's ~/Library/WebKit container) in place;
          by default they're deleted afterwards. A scratch dir given again reuses its stores.

Never touches the installed iSmith or its data: the Debug app has its own bundle id, and
ISMITH_DATA_DIR points it at the scratch folder. The Brave import offer is suppressed (a fixture
Brave root that doesn't exist, plus the first-run marker), so no macOS prompt appears.
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from memory import memory  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Build/Products/Debug/iSmith.app")
DEBUG_STORES = os.path.expanduser("~/Library/WebKit/com.scottsmith.ismith.debug/WebsiteDataStore")
SPACES = ["Contoso", "Fabrikam", "Personal", "Newtro Studios"]
TABS_PER_SPACE = 10


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


def read_stage(path):
    """(stage name, app pid), or None while the file is missing or half-written."""
    try:
        name, pid = open(path).read().split()
        return name, int(pid)
    except (OSError, ValueError):
        return None


def debug_pids(binary):
    """Running copies of this checkout's Debug binary (matched by its full path)."""
    out = subprocess.run(["pgrep", "-f", "^" + binary], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main():
    args = sys.argv[1:]
    keep = "--keep" in args
    args = [a for a in args if a != "--keep"]
    scratch = args[0] if args else tempfile.mkdtemp(prefix="ismith-perf-")
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
    # alive (Outlook and Teams in real use). A rerun on the same folder reuses its spaces' stores.
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
    with open(config_path, "w") as f:
        json.dump({"version": 2, "providers": [], "accounts": [], "shared": {}, "spaces": spaces}, f)
    with open(os.path.join(data, "session.json"), "w") as f:
        json.dump({"version": 2, "windows": [{"id": str(uuid.uuid4()).upper(), "frame": None,
                                              "activeSpace": spaces[0]["id"], "spaces": records}]}, f)
    open(os.path.join(data, "brave-import-offered"), "w").close()
    stage_file = os.path.join(scratch, "stage")
    for leftover in (stage_file, stage_file + ".json"):
        if os.path.exists(leftover):
            os.remove(leftover)

    # Launched through LaunchServices (not as a child of this script), so macOS counts the WebKit
    # processes as the app's own. The pid is this checkout's Debug binary started just now.
    binary = os.path.join(APP, "Contents/MacOS/iSmith")
    before = set(debug_pids(binary))
    subprocess.run(["open", "-n", "-a", APP, "--env", f"ISMITH_DATA_DIR={data}", "--env", f"ISMITH_PERF_STAGE_FILE={stage_file}",
                    "--env", f"ISMITH_BRAVE_ROOT={os.path.join(scratch, 'no-brave')}"], check=True)
    app_pid = None
    for _ in range(30):
        started_now = [p for p in debug_pids(binary) if p not in before]
        if started_now:
            app_pid = started_now[0]
            break
        time.sleep(0.5)
    seen = None
    samples = {}
    started = time.time()
    try:
        while time.time() - started < 900:
            time.sleep(1)
            stage = read_stage(stage_file)
            if stage is None:
                continue
            name, stage_pid = stage
            if app_pid is None:
                app_pid = stage_pid
            if name == "done":
                break
            if name != seen:
                seen = name
                time.sleep(4)  # let processes that are going away go
                taken = [memory(app_pid) for _ in range(3) if time.sleep(1) is None]
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
        # The app quits by itself after "done"; if the run failed, it's stopped (by pid: this
        # run's own Debug process only).
        if app_pid is not None:
            for _ in range(30):
                if not alive(app_pid):
                    break
                time.sleep(1)
            if alive(app_pid):
                os.kill(app_pid, signal.SIGTERM)
                time.sleep(3)
                if alive(app_pid):
                    os.kill(app_pid, signal.SIGKILL)
        # Stores are removed only once the app that used them is known to be gone.
        if not keep and app_pid is not None and not alive(app_pid):
            for space in spaces:
                shutil.rmtree(os.path.join(DEBUG_STORES, space["storeID"].lower()), ignore_errors=True)


if __name__ == "__main__":
    main()
