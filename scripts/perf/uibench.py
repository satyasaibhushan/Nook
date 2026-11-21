#!/usr/bin/env python3
"""Compare native browser UI from visible, timestamped 60 Hz display capture.

Runs preflight, desktop capture and offline analysis by default. Use --phase
preflight, --phase capture or --phase analyze with the same --out destination
to run the phases separately. Preflight writes a sibling -preflight.json report. Only capture uses the browser. --ax-mode none uses fresh
profiles, native window metadata and fixture beacons, with no target-app AX calls.
"""
from collections import Counter
import argparse
import base64
import ctypes
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid

import bench
from experiment import (CAPTURE_FREE_GIB, LOCK_WAIT, MAX_LOAD1, Interrupted, Invalid,
                        check_evidence, check_load, cooperative_signals, disk_headroom,
                        exclusive, finish_on_interrupt)
from uibench_evidence import Evidence, event_clock, recognize_input, validate_timeline, write_atomic, write_json

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name("uibench_capture.swift")
HELPER = ROOT / "build/hillclimb/bin/uibench-capture"
VIDEO = ROOT / "build/hillclimb/bin/loop.mp4"
DEFAULT_HELPER_TIMEOUT = 40
HELPER_TIMEOUT = DEFAULT_HELPER_TIMEOUT
SCENARIOS = ["keyboard", "click", "command", "navigate", "close", "sidebar_hide", "sidebar_show", "activate", "link", "scroll"]
ALIASES = dict(zip("abcdefghi", ["keyboard","click","command","navigate","close","sidebar_hide","activate","link","scroll"]))
COLORS = {"red": "#bd3645", "blue": "#285ea8", "green": "#269454"}
KEYS = {"t": 17, "w": 13, "l": 37, "s": 1, "f": 3, "j": 38, "a": 0,
        "return": 36, "escape": 53, "tab": 48, "home": 115, "backspace":51, ",": 43}


BUNDLED_HELPER = HELPER
OCR_TIMEOUT = 12
OCR_BUDGET = 120
INPUT_PROBE = "NOKPROBE"
AX_ONLY_SCENARIOS = {"click", "link", "sidebar_hide", "sidebar_show", "resources", "shots"}
WINDOW_KEYS = ("X", "Y", "Width", "Height")


class InstrumentationUnavailable(Invalid):
    pass


class Obstruction(Invalid):
    pass


class OwnedProcess:
    """A responsibility-isolated child spawned by the native helper."""
    def __init__(self, pid):
        self.pid = pid
        self.identity = None

    def identify(self):
        identity = run(["ps", "-p", self.pid, "-o", "lstart=,comm="], timeout=2).strip()
        if not identity:
            raise Invalid(f"ps could not identify process {self.pid}")
        self.identity = identity

    def poll(self):
        if self.identity is None:
            # The launch reply still gives us the PID if its identity lookup failed.
            try:
                os.kill(self.pid, 0)
            except ProcessLookupError:
                return 0
            return None
        identity = subprocess.run(["ps","-p",str(self.pid),"-o","lstart=,comm="], capture_output=True, text=True).stdout.strip()
        return None if identity and identity == self.identity else 0

    def send_signal(self, signum):
        if self.poll() is None:
            try:
                os.kill(self.pid, signum)
            except ProcessLookupError:
                pass

    def terminate(self):
        self.send_signal(signal.SIGTERM)

    def kill(self):
        self.send_signal(signal.SIGKILL)

    def wait(self, timeout=10):
        end = time.monotonic()+timeout
        while self.poll() is None and time.monotonic() < end:
            time.sleep(.1)
        if self.poll() is None:
            raise subprocess.TimeoutExpired("browser",timeout)


def log(text):
    print(text, file=sys.stderr, flush=True)


def run(args, timeout=40, **kwargs):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout, **kwargs)
    if result.returncode:
        raise Invalid(f"{Path(str(args[0])).name}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def helper(command, *args, timeout=None, **kwargs):
    result = json.loads(run([HELPER, command, *args], timeout=HELPER_TIMEOUT if timeout is None else timeout, **kwargs))
    if isinstance(result, dict) and result.get("error"):
        raise Invalid(result["error"])
    return result


def spec_call(command, spec):
    return helper(command, "-", input=json.dumps(spec))


def key(name, *flags, at=0.5):
    return {"kind": "key", "code": KEYS[name], "flags": list(flags), "at": at}


# The browser the benchmark launched; keyboard events are dropped unless it holds focus.
KEYBOARD_OWNER = None


def guarded(actions):
    return [{**a, "guard": KEYBOARD_OWNER} if KEYBOARD_OWNER and a.get("kind")
             in {"key", "text", "click", "move", "scroll"} else a for a in actions]


def act(*actions, require_window=True):
    if KEYBOARD_OWNER and any(a["kind"] in {"key", "text", "click", "scroll"} for a in actions):
        if require_window or window(KEYBOARD_OWNER):
            wait_for_clear_window(KEYBOARD_OWNER)
    events = spec_call("action", guarded(actions))
    if any(e.get("posted") is False for e in events):
        raise Invalid("setup input was withheld because the owned browser lost focus")
    return events


def text(value):
    return {"kind": "text", "text": value}


def processes():
    rows = {}
    for line in run(["ps", "-axo", "pid=,ppid=,rss=,comm="]).splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            pid, ppid, rss, command = fields
            rows[int(pid)] = {"ppid": int(ppid), "rss_kb": int(rss), "command": command}
    return rows


def target_window(pid, rows):
    return next((w for w in rows if w.get("kCGWindowOwnerPID") == pid
                 and w.get("kCGWindowLayer") == 0 and w["kCGWindowBounds"]["Width"] > 300
                 and w["kCGWindowBounds"]["Height"] > 300), None)


def window(pid):
    return target_window(pid, helper("windows"))


def obstruction_rows(pid, target, rows, allowed_owner=None):
    x, y, width, height = (target["kCGWindowBounds"][k] for k in WINDOW_KEYS)
    for row in rows:
        if row["kCGWindowNumber"] == target["kCGWindowNumber"]:
            break
        owner = row.get("kCGWindowOwnerPID")
        name, layer = row.get("kCGWindowOwnerName"), row.get("kCGWindowLayer")
        if owner == pid or (allowed_owner is not None and owner == allowed_owner):
            continue
        if (name, row.get("kCGWindowName"), layer) == ("Window Server", "Cursor", 2147483630):
            continue  # ScreenCaptureKit omits the cursor.
        rx, ry, rw, rh = (row["kCGWindowBounds"][k] for k in WINDOW_KEYS)
        if (rw > 0 and rh > 0
                and min(x+width, rx+rw) > max(x, rx) and min(y+height, ry+rh) > max(y, ry)):
            yield row


def wait_for_clear_window(pid, *, retry=True, allowed_owner=None, transparent_windows=None):
    # The budget includes every helper call and each retry sleep.
    deadline = time.monotonic() + min(HELPER_TIMEOUT, 3)
    reported = set()
    while True:
        rows = helper("windows", timeout=max(.01, deadline-time.monotonic()))
        target = target_window(pid, rows)
        if not target:
            raise Invalid("benchmark window is not on screen")
        blocked = []
        verified = []
        for row in obstruction_rows(pid, target, rows, allowed_owner):
            owner = row.get("kCGWindowOwnerName", "unknown")
            detail = f"{owner} (pid {row.get('kCGWindowOwnerPID')}, layer {row.get('kCGWindowLayer')})"
            if owner in {"Dock", "Notification Center", "NotificationCenter"} and not row.get("kCGWindowName"):
                try:
                    remaining = deadline-time.monotonic()
                    if remaining > 0 and helper("transparent-container", row["kCGWindowNumber"],
                                                row["kCGWindowOwnerPID"], timeout=remaining)["transparent"]:
                        verified.append(row)
                        continue
                except (Invalid, subprocess.TimeoutExpired):
                    pass  # An unverified surface can block input or contain a prompt.
            blocked.append(detail)
            if detail not in reported:
                log(f"foreign window overlaps benchmark: {detail}")
                reported.add(detail)
        if not blocked:
            if transparent_windows is not None:
                transparent_windows.extend(verified)
            return target
        report = "foreign window overlaps benchmark: " + ", ".join(blocked)
        remaining = deadline-time.monotonic()
        if not retry or remaining <= .2:
            raise Obstruction(report)
        time.sleep(min(.2, remaining))


def park_pointer(pid):
    visible = window(pid)
    if not visible:
        raise Invalid("cannot park pointer without an owned browser window")
    x, y, w, h = (visible["kCGWindowBounds"][k] for k in WINDOW_KEYS)
    pointer = {"kind": "move", "x": x+w*.85, "y": y+h*.75}
    act(pointer)
    return pointer


def quit_arc(path):
    with open(Path(path)/"Contents/Info.plist","rb") as f:
        info = plistlib.load(f)
    executable = str(Path(path).resolve()/"Contents/MacOS"/info["CFBundleExecutable"])
    ids = [p for p,r in processes().items() if r["command"] == executable]
    if not ids:
        return
    if len(ids) != 1:
        raise Invalid("multiple Arc instances found; graceful quit target is ambiguous")
    run(["osascript","-e",f'tell application id "{info["CFBundleIdentifier"]}" to quit'],timeout=20)
    end = time.monotonic()+20
    while ids[0] in processes() and time.monotonic() < end:
        time.sleep(.1)
    if ids[0] in processes():
        raise Invalid("Arc did not exit after AppleScript quit; no process was killed")


def leave_arc_running(path):
    run(["open","-a",str(path)])
    with open(Path(path)/"Contents/Info.plist","rb") as f:
        executable = str(Path(path).resolve()/"Contents/MacOS"/plistlib.load(f)["CFBundleExecutable"])
    end = time.monotonic()+20
    while time.monotonic() < end:
        ids = [p for p,r in processes().items() if r["command"] == executable]
        if ids:
            return ids[0]
        time.sleep(.1)
    raise Invalid("Arc did not relaunch")


def capture(pid, actions=(), duration=2, record=None, signatures=False, native=False, region=None,
            attribution=None, *, evidence, still=False, input_region=None, allowed_owner=None):
    transparent_windows = []
    visible = wait_for_clear_window(pid, allowed_owner=allowed_owner, transparent_windows=transparent_windows)
    with finish_on_interrupt():
        result = spec_call("capture", {
            "pid": pid, "window_id": visible["kCGWindowNumber"], "actions": guarded(actions),
            "duration": duration, "record": record is not None, "still": still,
            "signatures": signatures, "region": region, "native_resolution": native,
            "input_region": input_region, "input_until": 1.3, **(attribution or {}),
            "allowed_owner": allowed_owner, "transparent_windows": transparent_windows,
        })
        evidence.collect(result, record, still, needle=INPUT_PROBE if input_region else None)
    if result.get("capture_error"):
        raise Invalid(f"display capture failed: {result['capture_error']}")
    if obstruction := result.get("obstruction"):
        raise Obstruction(f"window obstructed during capture: {obstruction['reason']}")
    if not result.get("visibility_samples"):
        raise Invalid("capture delivered no in-stream window visibility samples")
    wait_for_clear_window(pid, retry=False)
    if any(event.get("posted") is False for event in result["events"]):
        raise Invalid("capture input was withheld because the owned browser lost focus")
    if len([f for f in result["frames"] if "changed" in f]) < (2 if actions else 1):
        raise Invalid("capture delivered too few complete frames")
    validate_timeline(result)
    return result


def summary(values):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return {"median": round(statistics.median(values), 2),
            "p95": round(values[max(0, math.ceil(len(values)*.95)-1)], 2),
            "min": round(values[0], 2), "max": round(values[-1], 2),
            "stdev": round(statistics.stdev(values), 2) if len(values) > 1 else 0}


def analyze(raw, target=None, scroll=False):
    event = raw["events"][0]
    t0, key_time = event_clock(event, raw.get("start"))
    complete = [f for f in raw["frames"] if "changed" in f]
    before = [f for f in complete if f["t"] < t0]
    if not before:
        raise Invalid("no pre-input reference frame")
    post = [f for f in complete if f["t"] >= t0]
    changed = [f for f in post if f["changed"] >= .0015]
    if not changed:
        raise Invalid("no visible response to input")
    if key_time is not None and changed[0]["t"] < event["key_post_time"]:
        raise Invalid("first changed frame precedes the target key post")
    if target:
        hits = [f for f in post if f.get(target, 0) > .20]
        if not hits or before[-1].get(target, 0) > .20:
            raise Invalid(f"destination {target} page not visually distinguished from source")
        paint = (hits[0]["t"] - t0)*1000
    else:
        paint = None
    last = changed[-1]["t"]
    if not scroll and raw["end"] - last < .25:
        raise Invalid("frame did not settle for 250 ms before capture ended")
    motion_end = t0 + 3 if scroll else last
    moving = [f for f in changed if f["t"] <= motion_end]
    gaps = [(b["t"] - a["t"])*1000 for a, b in zip(moving, moving[1:])]
    repeats = sum(max(0, round(g/1000*60)-1) for g in gaps)
    latency = (changed[0]["t"]-t0)*1000
    return {"first_change_ms": latency, "action_start_ms": latency,
            "key_to_frame_ms": (changed[0]["t"]-key_time)*1000 if key_time is not None else None,
            "first_paint_ms": paint, "settled_ms": None if scroll else (last-t0)*1000,
            "transition_ms": None if scroll else (last-changed[0]["t"])*1000,
            "dropped_frames": repeats, "worst_frame_gap_ms": max(gaps, default=0),
            "changed_frames": len(moving), "observed_fps": len(moving)/3 if scroll else None,
            "capture_complete_frames": len(complete),
            "frame_interval_median_ms": statistics.median(gaps) if gaps else None,
            "frame_interval_p95_ms": summary(gaps)["p95"] if gaps else None,
            "frame_interval_max_ms": max(gaps, default=0),
            "frame_intervals_over_20ms": sum(g > 20 for g in gaps)}


class Handler(bench.Handler):
    events = {}
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if not url.path.startswith("/ui/"):
            return super().do_GET()
        kind = url.path.split("/")[-1]
        if kind == "video.mp4":
            return self.reply("video/mp4", VIDEO.read_bytes()) if VIDEO.exists() else self.reply("text/plain", "unavailable", 404)
        q = urllib.parse.parse_qs(url.query)
        ident = q.get("id", ["unknown"])[0]
        color = q.get("color", ["red"])[0]
        dest = f"/ui/page?color=blue&id={ident}-next"
        extra = ""
        if kind == "long":
            extra = "".join(f"<section style='height:120px;background:hsl({i*31%360},65%,40%)'>Row {i}: {bench.words(20,i)}</section>" for i in range(600))
        if kind == "video":
            extra = """<button onclick="document.querySelector('video').play()">Start local video</button><br>
            <video autoplay muted loop playsinline controls width=640 src='/ui/video.mp4'></video>
            <script>setInterval(()=>{let v=document.querySelector('video');navigator.sendBeacon('/ui-event',JSON.stringify({
            id:new URLSearchParams(location.search).get('id'),kind:'video',wall:Date.now(),
            current:v.currentTime,paused:v.paused,hidden:document.hidden,ready:v.readyState}));},500)</script>"""
        script = ""
        if kind == "validate":
            script = """document.body.onclick=()=>setTimeout(()=>{
              document.body.style.background='#269454';
              navigator.sendBeacon('/ui-event',JSON.stringify({id:ID,kind:'color',wall:Date.now()}));
            },500);"""
        body = """<!doctype html><html lang=en><head><meta charset=utf-8><title>UIBENCH IDENT</title>
        <style>*{box-sizing:border-box}body{min-height:100vh;margin:0;background:COLOR;color:white;font:24px system-ui}
        header{padding:40px}a{color:white;display:block;padding:28px;background:#172c46}section{padding:20px}</style>
        </head><body><header>UIBENCH IDENT<br>Local browser benchmark</header>
        <a id=next href='DEST'>Open next local page</a>EXTRA<script>
        const ID='IDENT';
        function beacon(kind) { navigator.sendBeacon('/ui-event',JSON.stringify({id:ID,kind,wall:Date.now()})) }
        window.onload=()=>beacon('load');
        document.addEventListener('visibilitychange',()=>{ if (!document.hidden) beacon('visible') });
        SCRIPT
        </script></body></html>"""
        for token, value in [("COLOR", COLORS[color]), ("DEST", dest), ("EXTRA", extra), ("SCRIPT", script), ("IDENT", ident)]:
            body = body.replace(token, value)
        return self.reply("text/html; charset=utf-8", body)

    def do_POST(self):
        if self.path != "/ui-event":
            return super().do_POST()
        try:
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            self.events[(payload["id"], payload["kind"])] = payload
        except (ValueError, KeyError):
            pass
        self.reply("text/plain", "ok")


class Browser:
    def __init__(self, name, path, evidence):
        self.name, self.path = name, Path(path).resolve()
        self.evidence = evidence
        self.ax_mode = evidence.ax_mode
        with open(self.path / "Contents/Info.plist", "rb") as f:
            info = plistlib.load(f)
        self.bundle, self.version = info["CFBundleIdentifier"], info.get("CFBundleShortVersionString")
        self.exe = self.path / "Contents/MacOS" / info["CFBundleExecutable"]
        self.temp = tempfile.TemporaryDirectory(prefix=f"uibench-{name}-")
        self.proc = None
        self.pid = None
        self.owned_tabs = 0
        self.app = bench.App(str(self.path)) if name == "nook" else None
        self.session = uuid.uuid4().hex[:8]
        self.closed = False
        self.original_bounds = None

    def launch(self, normalize=True, prepare=True):
        initial = processes()
        if self.name == "arc":
            self.pid = next((pid for pid, row in initial.items() if row["command"] == str(self.exe)), None)
        if self.app:
            if self.bundle != "com.gstudios.nook.perf":
                raise Invalid("Nook UI benchmark requires com.gstudios.nook.perf")
            if any(row["command"] == str(self.exe) for row in initial.values()):
                raise Invalid("test Nook already running; refusing to interfere")
            self.app.defaults()
            args = [str(self.app.exe),"-NookStateDir",self.temp.name,"-NookDevMCPPort",str(bench.MCP_PORT),
                    "-ApplePersistenceIgnoreState","YES"]
            self.spawn(args, initial)
            self.app.proc = self.proc
            token = Path.home()/"Library/Application Support"/self.bundle/"dev-mcp-token"
            self.app.token = token.read_text().strip() if token.exists() else None
        elif not self.pid:
            args = [str(self.exe)]
            if self.name == "chrome":
                args += [f"--user-data-dir={self.temp.name}", "--no-first-run", "--no-default-browser-check"]
            if self.name == "zen":
                (Path(self.temp.name)/"user.js").write_text('user_pref("browser.shell.checkDefaultBrowser", false);\nuser_pref("zen.welcome-screen.seen", true);\nuser_pref("browser.startup.homepage_override.mstone", "ignore");\n')
                args += ["-profile", self.temp.name, "-no-remote", "-new-instance"]
            self.spawn(args, initial)
        global KEYBOARD_OWNER
        KEYBOARD_OWNER = self.pid
        deadline = time.monotonic() + 30
        self.activate()
        if self.name == "arc":
            time.sleep(.5)
            if not window(self.pid):
                act({"kind":"key", "code":45, "flags":["cmd"]}, require_window=False)
        while not window(self.pid) and time.monotonic() < deadline:
            time.sleep(.2)
        if not window(self.pid):
            raise Invalid("no browser window within 30 seconds; onboarding or launch blocked")
        if normalize and self.ax_mode == "inspected":
            if self.name == "arc":
                self.original_bounds = window(self.pid)["kCGWindowBounds"]
            self.inspect("resize")
            time.sleep(1)
        self.activate()
        if self.name == "arc" and prepare:
            self.close_library()
            self.navigate(self.url()[0], new=True)

    def spawn(self, args, initial):
        with finish_on_interrupt():
            launched = spec_call("launch", {"app": str(self.path), "args": args})
            if launched["pid"] in initial:
                raise Invalid("launch reused a pre-existing instance; refusing to drive or terminate it")
            self.proc = OwnedProcess(launched["pid"])
            self.pid, self.launch_time = self.proc.pid, launched["start"]
            self.proc.identify()

    def capture(self, *args, **kwargs):
        return capture(self.pid, *args, evidence=self.evidence, **kwargs)

    def close_library(self):
        if self.name != "arc":
            return
        menu = [r for r in self.ax() if r.get("AXRole") == "AXMenuItem" and r.get("AXTitle") == "Close Library"]
        if menu:
            self.inspect("press", ",".join(map(str,menu[0]["path"])))
            time.sleep(.3)

    def activate(self):
        act({"kind": "activate", "pid": self.pid})
        time.sleep(.15)

    def inspect(self, command, *args):
        if self.ax_mode != "inspected":
            raise Invalid(f"AX command {command} is unavailable in --ax-mode none")
        return helper(command, self.pid, *args)

    def ax(self):
        for attempt in range(3):
            rows = self.inspect("ax")
            if rows:
                return rows
            if attempt < 2:
                time.sleep(.1)
        raise InstrumentationUnavailable("AX returned an empty tree after three checks")

    def url(self, color="red", kind="page", ident=None):
        ident = ident or f"{self.session}-{uuid.uuid4().hex[:8]}"
        return f"{bench.HOST}/ui/{kind}?color={color}&id={ident}", ident

    def navigate(self, url, new=False):
        self.activate()
        if helper("front")["pid"] != self.pid:
            raise Invalid("browser did not become the foreground application")
        park_pointer(self.pid)
        act(key("escape"))
        act(key("t" if new else "l", "cmd")); time.sleep(.2)
        if new:
            self.owned_tabs += 1
        act(key("a", "cmd"), text(url), key("return"))
        ident = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("id", [None])[0]
        for attempt in range(1 if self.name == "arc" else 2):
            if attempt:
                # Retry setup in the current throwaway tab if focus swallowed input.
                act(key("l", "cmd"), key("a", "cmd"), text(url), key("return"))
            end = time.monotonic()+5
            while ident and (ident, "load") not in Handler.events and time.monotonic() < end:
                time.sleep(.05)
            if not ident or (ident, "load") in Handler.events:
                break
        if ident and (ident, "load") not in Handler.events:
            raise Invalid("typed local URL did not load during bounded setup attempts")
        time.sleep(.35)
        return ident

    def page(self, color="red", kind="page", new=False):
        if self.name == "arc" and not new and not self.owns_current_tab():
            new = True
        url, ident = self.url(color, kind)
        self.navigate(url, new)
        return ident

    def owns_current_tab(self, ident=None):
        rows = self.inspect("ax-focused")
        for row in rows:
            url = str(row.get("AXURL", ""))
            ids = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("id", [])
            if row.get("AXRole") == "AXWebArea" and url.startswith(bench.HOST+"/ui/") and ids:
                return ids == [ident] if ident else ids[0].startswith(self.session+"-")
        return False

    def select_owned_tab(self, row):
        title = row.get("AXTitle", "")
        if not title.startswith(f"UIBENCH {self.session}-"):
            raise Invalid("tab identity is not owned by this benchmark")
        ident = title.split()[1]
        try:
            self.inspect("press", ",".join(map(str,row["path"])))
        except Invalid:
            act(self.click(row))
        time.sleep(.1)
        if helper("front")["pid"] != self.pid or not self.owns_current_tab(ident):
            raise Invalid("selected tab identity could not be verified; refusing to close it")

    def close_tab(self):
        if self.name == "arc" and not self.owns_current_tab():
            self.select_owned_tab(self.locate(f"UIBENCH {self.session}-", {"AXButton", "AXTab", "AXRadioButton"}))
        if helper("front")["pid"] != self.pid:
            raise Invalid("browser is not foreground; refusing to close a tab")
        act(key("w","cmd"))

    def nodes(self, needle, roles=None):
        found = []
        for row in self.ax():
            if roles and row.get("AXRole") not in roles:
                continue
            rect = row.get("rect")
            if not rect or rect[2] < 4 or rect[3] < 4:
                continue
            if needle.lower() in " ".join(str(row.get(k, "")) for k in ("AXTitle", "AXDescription", "AXValue", "AXURL")).lower():
                found.append(row)
        return found

    def locate(self, needle, roles=None):
        end = time.monotonic()+3
        rows = self.nodes(needle, roles)
        while not rows and time.monotonic() < end:
            time.sleep(.1)
            rows = self.nodes(needle, roles)
        if not rows:
            raise Invalid(f"no visible accessible control matching {needle!r}")
        return min(rows, key=lambda r: r["rect"][2]*r["rect"][3])

    def click(self, row, **extra):
        x, y, w, h = row["rect"]
        return {"kind": "click", "x": x+w*.5, "y": y+h*.5, **extra}

    def pids(self):
        rows = processes()
        ids = {self.pid} & rows.keys()
        changed = True
        while changed:
            extra = {pid for pid, row in rows.items() if row["ppid"] in ids}
            changed = not extra.issubset(ids)
            ids |= extra
        # WebKit XPC services have launchd as parent. Responsibility links them to
        # this exact app PID instead of accidentally counting the daily browser.
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        try:
            responsible = library.responsibility_get_pid_responsible_for_pid
        except AttributeError:
            if self.name == "nook":
                raise Invalid("cannot attribute WebKit helpers: responsibility API unavailable")
        else:
            responsible.argtypes, responsible.restype = [ctypes.c_int], ctypes.c_int
            ids |= {pid for pid in rows if responsible(pid) == self.pid}
            if self.name == "nook" and responsible(self.pid) != self.pid:
                raise Invalid("test browser inherited launcher responsibility; helper totals would be incomplete")
        return sorted(ids)

    def resources(self):
        ids = self.pids()
        if self.pid not in ids:
            raise Invalid("browser process exited before resource snapshot")
        usage = helper("footprint", *ids)
        if any("error" in row for row in usage.values()):
            raise Invalid("kernel denied footprint for a browser helper")
        rows = processes()
        return {"pids": ids, "rss_mb": sum(rows.get(pid, {}).get("rss_kb", 0) for pid in ids)/1024,
                "physical_mb": sum(row["physical_bytes"] for row in usage.values())/1024**2,
                "cpu_s": sum(row["cpu_ns"] for row in usage.values())/1e9}

    def cpu(self, duration, action=None):
        start = self.resources(); t0 = time.monotonic()
        if action:
            action()
        remaining = duration-(time.monotonic()-t0)
        if remaining > 0:
            time.sleep(remaining)
        end = self.resources(); elapsed = time.monotonic()-t0
        if set(start["pids"])-set(end["pids"]):
            raise Invalid("browser helper exited during CPU interval; cumulative CPU incomplete")
        return {"percent": (end["cpu_s"]-start["cpu_s"])/elapsed*100,
                "seconds": elapsed, "start": start, "end": end}

    def cleanup(self):
        global KEYBOARD_OWNER
        if self.closed:
            return
        self.closed = True
        with finish_on_interrupt():
            try:
                if self.name == "arc" and self.pid and (self.proc is None or self.proc.identity is not None):
                    self.cleanup_arc_tabs()
            finally:
                try:
                    self.stop_owned_process()
                finally:
                    self.temp.cleanup()
                    if KEYBOARD_OWNER == self.pid:
                        KEYBOARD_OWNER = None

    def cleanup_arc_tabs(self):
        # Close only explicitly-created local benchmark tabs, selected by AX.
        try:
            self.activate()
            self.close_library()
            for _ in range(self.owned_tabs+3):
                tabs = self.nodes(f"UIBENCH {self.session}-", {"AXRadioButton", "AXTab", "AXButton"})
                tabs = [r for r in tabs if r.get("rect", [0,0,9999])[2] < 500]
                if not tabs:
                    break
                self.select_owned_tab(tabs[0])
                self.close_tab()
                time.sleep(.15)
        except (Invalid, subprocess.TimeoutExpired) as error:
            self.cleanup_error = str(error)
            log(f"Arc cleanup stopped: {error}")
        finally:
            if self.original_bounds:
                self.inspect("resize", *(self.original_bounds[k] for k in WINDOW_KEYS))

    def stop_owned_process(self):
        if not self.proc or self.proc.poll() is not None:
            return
        if self.name == "arc" and self.proc.identity is not None:
            quit_arc(self.path)
            return
        children = []
        try:
            if self.proc.identity is not None:
                for pid in self.pids():
                    if pid != self.pid:
                        child = OwnedProcess(pid)
                        try:
                            child.identify()
                        except Invalid:
                            continue  # The helper exited between process snapshots.
                        children.append(child)
        finally:
            try:
                self.proc.terminate()
                try:
                    self.proc.wait(8)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()
            finally:
                for child in children:
                    child.terminate()


def wait_for_beacon(ident, kind, timeout=2):
    deadline = time.monotonic()+timeout
    while (ident, kind) not in Handler.events and time.monotonic() < deadline:
        time.sleep(.05)
    return Handler.events.get((ident, kind))


def validation(browser, record):
    ident = browser.page(kind="validate")
    w = window(browser.pid)["kCGWindowBounds"]
    raw = browser.capture([{"kind": "click", "x": w["X"]+w["Width"]*.7,
                                "y": w["Y"]+w["Height"]*.7, "at": .5}], 2, record)
    event = Handler.events.get((ident, "color"))
    if not event:
        raise Invalid("synthetic color-change beacon missing")
    clock = raw["clock"]
    known = event["wall"]/1000 + clock["host_seconds"] - clock["wall_seconds"]
    first = next((f["t"] for f in raw["frames"] if f.get("green", 0) > .2), None)
    delta = (first-known)*1000 if first else None
    delay = (known-raw["events"][0]["t"])*1000
    if delta is None or not -20 <= delta <= 100 or not 450 <= delay <= 650:
        raise Invalid(f"synthetic calibration failed: capture error {delta} ms, scheduled delay {delay:.1f} ms")
    return {"status": "valid", "scheduled_delay_ms": 500, "observed_page_delay_ms": delay,
            "capture_after_known_change_ms": delta, "raw": raw}


def isolation_manifest(names):
    stores = {
        "nook": {
            "temporary": ["Tab state under -NookStateDir"],
            "bundle_shared": [
                "SwiftData store and browsing history at ~/Library/Application Support/com.gstudios.nook.perf/default.store",
                "User defaults and Dev MCP token for com.gstudios.nook.perf",
            ],
            "shared": [
                "Persistent WebKit website data keyed by profile ID",
                "Favicon disk cache at ~/Library/Caches/FaviconCache, shared across Nook bundle IDs",
            ],
        },
        "chrome": {"temporary": ["Chrome user data, including history and profile caches, under --user-data-dir"]},
        "zen": {"temporary": ["Zen profile, including history and profile caches, under -profile"]},
        "arc": {"shared": ["Persistent Arc profile, including history and caches"]},
    }
    return {
        "filesystem_cache": "Left warm (no cache flush)",
        "browsers": {name: stores[name] for name in names},
    }


def launch_label(name):
    history = {
        "nook": "shared SwiftData history",
        "arc": "shared Arc profile history",
        "chrome": "temporary Chrome profile",
        "zen": "temporary Zen profile",
    }
    return f"Fresh process with warm filesystem cache and {history[name]}"


def cold_launch(name, path, runs, record, allow_arc_quit=False, *, evidence, entry):
    entry["label"] = launch_label(name)
    if name == "arc" and not allow_arc_quit:
        entry.update(status="discarded", reason="Arc has no profile flag and its existing instance must remain running")
        return
    samples = entry["runs"] = []
    for index in range(runs):
        if name == "arc":
            quit_arc(path)
        trial = {"status": "pending"}
        samples.append(trial)
        with evidence.attach(trial), tempfile.TemporaryDirectory(prefix="uibench-cold-") as temporary:
            ready = Path(temporary)/"ready"
            recording = record/f"{index+1:02d}" if record else None
            spec = {"duration":8, "signatures":True, "ready_file":str(ready), "record": bool(recording)}
            specpath = Path(temporary)/"spec.json"; specpath.write_text(json.dumps(spec))
            process = browser = raw = None
            try:
                with finish_on_interrupt():
                    process = subprocess.Popen([str(HELPER), "capture", str(specpath)], stdout=subprocess.PIPE,
                                               stderr=subprocess.PIPE, text=True)
                browser = Browser(name, path, evidence)
                deadline = time.monotonic()+10
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                if not ready.exists():
                    raise Invalid("pre-launch capture never became ready")
                time.sleep(.25)
                browser.launch(normalize=False,prepare=False)
                start = browser.launch_time
                with finish_on_interrupt():
                    output, errors = process.communicate(timeout=15)
                    if process.returncode:
                        raise Invalid(errors or output)
                    raw = evidence.collect(json.loads(output), recording)
                if raw.get("capture_error"):
                    raise Invalid(f"display capture failed: {raw['capture_error']}")
                w = wait_for_clear_window(browser.pid, retry=False)
                bounds = w["kCGWindowBounds"]
                x0,y0,width,height = raw["rect"]
                cells = [(y*160+x)*3 for y in range(100) for x in range(160)
                         if bounds["X"]+10 <= x0+x*width/160 < bounds["X"]+bounds["Width"]-10
                         and bounds["Y"]+40 <= y0+y*height/100 < bounds["Y"]+bounds["Height"]-10]
                frames = [f for f in raw["frames"] if "pixels" in f]
                if not frames or not cells:
                    raise Invalid("cold launch capture has no complete frames or visible window pixels")
                reference = base64.b64decode(frames[-1]["pixels"])
                matches = []
                for frame in frames:
                    pixels = base64.b64decode(frame.pop("pixels"))
                    likeness = sum(sum(abs(pixels[i+c]-reference[i+c]) for c in range(3)) <= 30 for i in cells)/max(1,len(cells))
                    frame["final_window_similarity"] = likeness
                    if likeness >= .97 and frame["t"] >= start:
                        matches.append(frame["t"])
                    if likeness >= .97 and frame["t"] < start:
                        raise Invalid("pre-launch desktop already matches final browser window")
                if not matches:
                    raise Invalid("no captured full window matching settled frame")
                trial.update(status="valid", first_full_window_ms=(matches[0]-start)*1000,
                             raw=raw, reference_rect=bounds)
            except (Invalid, OSError, subprocess.TimeoutExpired) as error:
                trial.update(status="discarded", reason=str(error))
            finally:
                with finish_on_interrupt():
                    try:
                        if process:
                            if ready.exists() and raw is None and trial.get("status") != "valid":
                                try:
                                    output, _ = process.communicate(timeout=10)
                                    if process.returncode == 0:
                                        evidence.collect(json.loads(output), recording)
                                except (ValueError, subprocess.TimeoutExpired):
                                    pass
                            stop_child(process)
                    finally:
                        if browser:
                            browser.cleanup()
    valid = [s["first_full_window_ms"] for s in samples if s["status"] == "valid"]
    entry.update(status="valid" if len(valid) >= 10 else "discarded", n=len(valid),
                 first_full_window_ms=summary(valid),
                 definition="Launch start to the first post-launch frame 97% matching the final window content")


def scenario(browser, name, index, record):
    browser.activate()
    actions, target, duration = [], None, 2.2
    occluder = None
    region = None
    pointer = park_pointer(browser.pid)
    if name in ("keyboard", "click", "close"):
        source = browser.page("red")
        destination = browser.page("blue", new=True)
        if name == "keyboard":
            actions = [key("tab", "ctrl")] if browser.name in {"nook","arc","zen"} else [key("tab", "ctrl", "shift")]
        elif name == "click":
            row = browser.locate(source, {"AXRadioButton", "AXTab", "AXButton"})
            actions = [browser.click(row, at=.5)]
        else:
            actions = [key("w", "cmd")]
        target = "red"
    elif name == "command":
        browser.page()
        actions = [key("t", "cmd")]
    elif name == "navigate":
        browser.page("red")
        url, ident = browser.url("blue")
        act(key("l", "cmd")); time.sleep(.15)
        act(key("a", "cmd"), text(url)); time.sleep(.3)
        actions, target = [key("return")], "blue"
    elif name in ("sidebar_hide", "sidebar_show"):
        if browser.name == "chrome":
            raise Invalid("no comparable tab sidebar toggle")
        browser.page()
        actions = [key("s", "cmd", *( ["alt"] if browser.name == "zen" else []))]
        sidebar_before = browser.ax()
        menus = [r for r in sidebar_before if r.get("AXRole") == "AXMenuItem"
                 and r.get("AXTitle","").lower().replace(" ","") in {"showsidebar","hidesidebar","togglesidebar"}
                 and isinstance(r.get("AXMenuItemCmdVirtualKey"),int)]
        if menus:
            menu = menus[0]; mask = menu.get("AXMenuItemCmdModifiers",0)
            modifiers = ([] if mask & 8 else ["cmd"])+(["shift"] if mask & 1 else [])+(["alt"] if mask & 2 else [])+(["ctrl"] if mask & 4 else [])
            actions = [{"kind":"key","code":menu["AXMenuItemCmdVirtualKey"],"flags":modifiers,"at":.5}]
    elif name == "activate":
        browser.page()
        bounds = window(browser.pid)["kCGWindowBounds"]
        region = [bounds[k] for k in ("X","Y","Width","Height")]
        actions, target = [{"kind": "activate", "pid": browser.pid, "at": .5}], "red"
    elif name == "link":
        browser.page()
        actions = [browser.click(browser.locate("Open next local page", {"AXLink"}), at=.5)]
        target = "blue"
    elif name == "scroll":
        browser.page(kind="long")
        bounds = window(browser.pid)["kCGWindowBounds"]
        act({"kind":"move","x":bounds["X"]+bounds["Width"]*.7,"y":bounds["Y"]+bounds["Height"]*.7})
        actions = [{"kind": "scroll", "dy": -24, "at": .5+i/60} for i in range(180)]
        duration = 4.1
    if name in ("sidebar_hide", "sidebar_show"):
        def sidebar_visible(rows):
            labels = [r.get("AXTitle", "").lower().replace(" ", "") for r in rows if r.get("AXRole") == "AXMenuItem"]
            if "hidesidebar" in labels: return True
            if "showsidebar" in labels: return False
            pages = [r["rect"] for r in rows if r.get("AXRole") == "AXWebArea" and browser.session in str(r.get("AXURL","")) and "rect" in r]
            bounds = window(browser.pid)["kCGWindowBounds"]
            if pages: return bounds["Width"]-pages[0][2] > 100
            raise Invalid("cannot establish sidebar direction from menu state or viewport")
        bounds = window(browser.pid)["kCGWindowBounds"]
        pointer = {"kind":"move","x":bounds["X"]+bounds["Width"]*.85,"y":bounds["Y"]+bounds["Height"]*.75}
        act(pointer)
        time.sleep(.3)
        want_visible = name == "sidebar_hide"
        if sidebar_visible(sidebar_before) != want_visible:
            act(actions[0]); time.sleep(.5)
            sidebar_before = browser.ax()
        if sidebar_visible(sidebar_before) != want_visible:
            raise Invalid("sidebar precondition did not match requested direction")
    bounds = window(browser.pid)["kCGWindowBounds"] if name != "activate" else bounds
    window_rect = [bounds[k] for k in ("X","Y","Width","Height")]
    attribution = None
    if name == "activate":
        # The lower-right blank page contains no fixture links or browser controls.
        pointer = {"kind":"move","x":bounds["X"]+bounds["Width"]*.85,"y":bounds["Y"]+bounds["Height"]*.75}
        act(pointer); time.sleep(.3)
        x,y,w,h = window_rect
        regions = []
        if browser.ax_mode == "inspected":
            page = next((r["rect"] for r in browser.ax() if r.get("AXRole") == "AXWebArea"
                         and browser.session in str(r.get("AXURL", "")) and "rect" in r), None)
            if not page:
                raise Invalid("cannot identify the benchmark page rectangle")
            px, py, pw, _ = page
            regions = [
                {"name":"traffic_lights","rect":[x,y,90,38]},
                {"name":"link_pill","rect":[px,y+h-44,min(500,pw),44]},
                {"name":"page","rect":page},
                {"name":"chrome_title","rect":[x,y,w,max(40,py-y)]},
                {"name":"sidebar","rect":[x,y,max(0,px-x),h]},
            ]
        regions.append({"name": "window", "rect": window_rect})
        attribution = {"attribute":True,"full_display":True,"window_rect":window_rect,"regions":regions}
        region = [x-20,y-20,w+40,h+40]
    sampler = None
    start = browser.resources() if name == "scroll" else None
    t0 = time.monotonic()
    try:
        if name == "activate":
            attribution["window_id"] = window(browser.pid)["kCGWindowNumber"]
            with finish_on_interrupt():
                occluder = subprocess.Popen([str(HELPER), "occlude", *map(str,window_rect)],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(.35)
        if getattr(browser, "sample_main", False) and record:
            with finish_on_interrupt():
                sampler = subprocess.Popen(
                    ["/usr/bin/sample", str(browser.pid), str(math.ceil(duration+1)), "1", "-file", "/dev/stdout"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                )
        raw = browser.capture(actions, duration, record, signatures=name == "activate",
                              region=region, attribution=attribution, allowed_owner=occluder.pid if occluder else None)
        if start is not None:
            end = browser.resources()
            elapsed = time.monotonic()-t0
    finally:
        with finish_on_interrupt():
            try:
                if sampler:
                    try:
                        output, _ = sampler.communicate(timeout=20)
                        if sampler.returncode == 0:
                            browser.evidence.files[record/"main-thread.sample.txt"] = output
                    except subprocess.TimeoutExpired:
                        stop_child(sampler)
            finally:
                if occluder:
                    stop_child(occluder)
    if name in ("sidebar_hide", "sidebar_show"):
        try:
            sidebar_after = browser.ax()
        finally:
            # Restore the known precondition even if AX instrumentation went away.
            if name == "sidebar_hide":
                act(actions[0]); time.sleep(.3)
        def viewport(rows):
            return [r["rect"] for r in rows if r.get("AXRole") == "AXWebArea" and browser.session in str(r.get("AXURL","")) and "rect" in r]
        def labels(rows):
            return {r.get("AXTitle","") for r in rows if r.get("AXRole") == "AXMenuItem" and "sidebar" in r.get("AXTitle","").lower()}
        before, after = viewport(sidebar_before), viewport(sidebar_after)
        resized = bool(before and after and (abs(before[0][0]-after[0][0]) > 50 or abs(before[0][2]-after[0][2]) > 50))
        if not resized and labels(sidebar_before) == labels(sidebar_after):
            raise Invalid("shortcut did not change the page viewport or sidebar menu state")
        raw["sidebar_validation"] = {"before":before,"after":after,"menu_before":sorted(labels(sidebar_before)),"menu_after":sorted(labels(sidebar_after))}
    raw["window_frame"] = bounds
    raw["pointer_park"] = pointer
    if actions[0]["kind"] in ("activate", "key"):
        observed = raw["events"][0].get("pointer_before")
        raw["pointer_park_verified"] = bool(observed and abs(observed[0]-pointer["x"]) < 2 and abs(observed[1]-pointer["y"]) < 2)
        if not raw["pointer_park_verified"]:
            raise Invalid(f"pointer was not parked in the owned window: {observed}")
    if name == "activate":
        for frame in raw["frames"]:
            if "window_changed_fraction" in frame:
                frame["display_changed_fraction"] = frame["changed"]
                frame["changed"] = frame["window_changed_fraction"]
    metrics = analyze(raw, target, name == "scroll")
    if name == "activate":
        frames = [f for f in raw["frames"] if "pixels" in f]
        reference = base64.b64decode(frames[-1]["pixels"])
        matches = []
        x0,y0,cw,ch = raw["rect"]
        cells = [(y*160+x)*3 for y in range(100) for x in range(160)
                 if bounds["X"] <= x0+x*cw/160 < bounds["X"]+bounds["Width"]
                 and bounds["Y"] <= y0+y*ch/100 < bounds["Y"]+bounds["Height"]]
        for frame in frames:
            pixels = base64.b64decode(frame.pop("pixels"))
            similarity = sum(sum(abs(pixels[i+c]-reference[i+c]) for c in range(3)) <= 30 for i in cells)/len(cells)
            frame["final_window_similarity"] = similarity
            if similarity >= .97:
                matches.append(frame["t"])
        t0 = raw["events"][0]["t"]
        if not matches or matches[0] < t0:
            raise Invalid("activation did not expose a newly visible full browser frame")
        metrics["first_full_frame_ms"] = (matches[0]-t0)*1000
        significant = [f["t"] for f in frames if f["t"] >= t0 and f.get("window_changed_fraction",0) > .005]
        metrics["visually_complete_ms"] = (max(significant)-t0)*1000 if significant else None
        raw["tail_after_97"] = [{"t":f["t"],"ms":(f["t"]-t0)*1000,"window_changed_fraction":f["window_changed_fraction"],"regions":f["regions"]}
                                for f in frames if f["t"] > matches[0] and f.get("regions")]
        raw["region_definitions"] = attribution["regions"]
    if name == "scroll":
        moving = [f["t"] for f in raw["frames"] if raw["events"][0]["t"] <= f["t"] <= raw["events"][0]["t"]+3 and f.get("changed",0) >= .0015]
        raw["frame_intervals"] = [{"start":a,"end":b,"ms":(b-a)*1000} for a,b in zip(moving,moving[1:])]
        raw["resources"] = {"before": start, "after": end, "elapsed_s": elapsed}
        metrics["cpu_percent"] = (end["cpu_s"]-start["cpu_s"])/elapsed*100
    if name == "command":
        raw["readiness"] = {}
        command_readiness(browser, bounds, record, raw["readiness"])
    if name in ("keyboard", "click"):
        # Select the known blue fixture before closing that tab.
        if browser.ax_mode == "none":
            Handler.events.pop((destination, "visible"), None)
            act(key("tab", "ctrl", *(("shift",) if browser.name != "chrome" else ())))
            if not wait_for_beacon(destination, "visible"):
                raise Invalid("blue fixture did not confirm visibility before tab cleanup")
        else:
            row = browser.locate(destination, {"AXRadioButton", "AXTab", "AXButton"})
            if browser.name == "arc":
                browser.select_owned_tab(row)
            else:
                act(browser.click(row)); time.sleep(.15)
        browser.close_tab()
        browser.owned_tabs -= 1
    if name == "close":
        browser.owned_tabs -= 1
    return {"status": "valid", **metrics, "raw": raw}


def stop_child(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=5)


def input_region(bounds, focused=None):
    x, y, w, h = (bounds[k] for k in WINDOW_KEYS)
    if focused and "rect" in focused:
        fx, fy, fw, fh = focused["rect"]
        if 4 <= fw <= w and 4 <= fh <= 120:
            return [fx-8, fy-8, fw+16, fh+16]
    # The toolbar and the centered command palette both live in this band.
    return [x, y, w, min(h*.45, 360)]


def command_readiness(browser, bounds, record, readiness):
    readiness.update(capture_status="pending", browser_status="unchecked", recognition={"status": "pending"})
    focused = None
    if browser.ax_mode == "inspected":
        try:
            focused = next((r for r in browser.ax() if r.get("AXFocused")
                            and r.get("AXRole") in {"AXTextField", "AXSearchField", "AXComboBox"}), None)
            readiness["instrumentation"] = "inspected" if focused else "focused field absent"
        except (Invalid, subprocess.TimeoutExpired) as error:
            readiness["instrumentation"] = str(error)
    try:
        act(key("escape"))
        if browser.name == "chrome":
            act(key("w", "cmd"))
        park_pointer(browser.pid)
    except (Invalid, subprocess.TimeoutExpired) as error:
        readiness.update(capture_status="failed", capture_reason=str(error))
        return
    url, ident = browser.url()
    probes = [{"kind": "text", "text": f"{INPUT_PROBE} ", "at": .55+i*.05} for i in range(10)]
    try:
        # Submit a unique local URL through the same field after the timed probes.
        # A beacon proves input worked even if the OCR process later stalls.
        raw = browser.capture([key("t", "cmd"), *probes, key("a", "cmd", at=1.3),
                               {**text(url), "at": 1.4}, key("return", at=1.6)],
                              2, record/"readiness" if record else None,
                              input_region=input_region(bounds, focused))
        readiness.update(capture_status="captured", capture=raw)
    except (Invalid, subprocess.TimeoutExpired) as error:
        readiness.update(capture_status="failed", capture_reason=str(error))
    beacon = wait_for_beacon(ident, "load")
    if beacon:
        readiness.update(browser_status="responsive", functional_input=beacon)
        try:
            browser.close_tab()
        except (Invalid, subprocess.TimeoutExpired) as error:
            readiness["cleanup_reason"] = str(error)
    else:
        readiness.update(browser_status="failed", browser_reason="submitted local URL did not load")
        try:
            act(key("escape"))
        except (Invalid, subprocess.TimeoutExpired) as error:
            readiness["cleanup_reason"] = str(error)


def resource_scenarios(browser, allow_arc_quit=False):
    if browser.name == "arc" and not allow_arc_quit:
        raise Invalid("Arc has pre-existing tabs and no throwaway profile; absolute 1/10/30-tab resources and cold launch would be misleading")
    result = {"memory": {}}
    if browser.name == "arc":
        result["context"] = "Persistent Arc profile after a fresh launch; pre-existing tabs preserved; counts are added local tabs"
        old = [r for r in browser.nodes("UIBENCH ", {"AXButton", "AXTab", "AXRadioButton"})
               if r.get("AXTitle", "").startswith("UIBENCH ") and not r.get("AXTitle", "").startswith(f"UIBENCH {browser.session}-")]
        if old:
            raise Invalid(f"Arc retains {len(old)} local benchmark tabs from earlier sessions; 1/10/30 local-tab resources cannot be validated")
    browser.page()
    count = 1
    for wanted in (1, 10, 30):
        while count < wanted:
            browser.page(new=True); count += 1
        time.sleep(2)
        result["memory"][str(wanted)] = browser.resources()
        if wanted == 10:
            log(f"{browser.name}: sampling 30 seconds idle CPU")
            try:
                result["idle_10_tabs"] = browser.cpu(30)
            except Invalid as error:
                result["idle_10_tabs"] = {"status":"discarded","reason":str(error)}
    for _ in range(20):
        browser.close_tab(); time.sleep(.08)
    if VIDEO.exists():
        ident = browser.page(kind="video", new=True)
        act(browser.click(browser.locate("Start local video", {"AXButton"})))
        time.sleep(2)
        act(key("tab", "ctrl", "shift")); time.sleep(1)
        before = Handler.events.get((ident,"video"))
        measurement = browser.cpu(15)
        after = Handler.events.get((ident,"video"))
        if not before or not after or after["paused"] or not after["hidden"] or after["ready"] < 2 or after["wall"] <= before["wall"]:
            result["background_video"] = {"status":"discarded", "reason":"background muted video playback not confirmed", "playback":after}
        else:
            result["background_video"] = {**measurement,"playback":after}
    else:
        result["background_video"] = {"status": "discarded", "reason": "local looping MP4 unavailable"}
    return result


def screenshots(browser, folder):
    result = {}
    def close_created_window(before):
        created = [w for w in helper("windows") if w.get("kCGWindowOwnerPID") == browser.pid
                   and w.get("kCGWindowLayer") == 0 and w["kCGWindowBounds"]["Width"] > 300
                   and w["kCGWindowNumber"] not in before]
        if not created:
            return False
        target = created[0]
        bounds = target["kCGWindowBounds"]
        browser.inspect("close-window", *(bounds[k] for k in WINDOW_KEYS))
        deadline = time.monotonic()+2
        while any(w["kCGWindowNumber"] == target["kCGWindowNumber"] for w in helper("windows")) and time.monotonic() < deadline:
            time.sleep(.1)
        if any(w["kCGWindowNumber"] == target["kCGWindowNumber"] for w in helper("windows")):
            raise Invalid("created UI window remained open after its close button was pressed")
        return True
    def shot(name, verify=None, region=None):
        if verify and not verify():
            raise Invalid(f"{name} surface did not appear")
        browser.capture(duration=.6, record=folder/f"{name}.png", native=True, region=region, still=True)
        result[name] = str(folder/f"{name}.png")
    browser.page()
    shot("default")
    for _ in range(7):
        browser.page(new=True)
    shot("eight-tabs")
    for name, action in [("command", key("t", "cmd")), ("find", key("f", "cmd"))]:
        bounds = window(browser.pid)["kCGWindowBounds"]
        region = [bounds[k] for k in ("X","Y","Width","Height")]
        act(action); time.sleep(.3)
        act(text("UIBENCH")); time.sleep(.8)
        try:
            shot(name, lambda: any("UIBENCH" in str(r.get("AXValue", "")) and r.get("AXRole") in {"AXTextField", "AXComboBox", "AXSearchField"} for r in browser.ax()),region=region)
        except Invalid as e:
            result[name] = {"status": "discarded", "reason": str(e)}
        act(key("escape")); time.sleep(.3)
        if name == "command" and browser.name == "chrome":
            act(key("w","cmd")); time.sleep(.2)
        if name == "find":
            if browser.name == "nook":
                act(key("f", "cmd")); time.sleep(.2)
            bounds = window(browser.pid)["kCGWindowBounds"]
            act({"kind":"click","x":bounds["X"]+bounds["Width"]*.75,"y":bounds["Y"]+bounds["Height"]*.8})
            time.sleep(.2)
    tabs = browser.nodes(f"UIBENCH {browser.session}-", {"AXRadioButton", "AXTab", "AXButton"})
    if tabs:
        tab = min(tabs, key=lambda r:r["rect"][2]*r["rect"][3])
        action = browser.click(tab); action["kind"] = "move"
        act(action); time.sleep(.7); shot("tab-hover")
        act(browser.click(tab, right=True)); time.sleep(.3); shot("tab-context")
        act(key("escape"))
    else:
        for name in ("tab-hover", "tab-context"):
            result[name] = {"status": "discarded", "reason": "tab control absent from accessibility tree"}
    before_downloads = {w["kCGWindowNumber"] for w in helper("windows") if w.get("kCGWindowOwnerPID") == browser.pid}
    act(key("j", "cmd", *( [] if browser.name == "zen" else ["shift"]))); time.sleep(.8)
    shot("downloads")
    after_downloads = {w["kCGWindowNumber"] for w in helper("windows") if w.get("kCGWindowOwnerPID") == browser.pid}
    web_downloads = [r for r in browser.ax() if r.get("AXRole") == "AXWebArea" and "downloads" in str(r.get("AXURL", ""))]
    if close_created_window(before_downloads):
        pass
    elif web_downloads:
        act(key("w", "cmd"))
    else:
        act(key("escape"))
    browser.close_library()
    if browser.name == "nook":
        bounds = window(browser.pid)["kCGWindowBounds"]
        back = [r for r in browser.nodes("Back", {"AXButton"}) if r["rect"][1] > bounds["Y"]+bounds["Height"]*.8]
        if back:
            act(browser.click(back[0])); time.sleep(.3)
    browser.page()
    before_windows = {w["kCGWindowNumber"] for w in helper("windows") if w.get("kCGWindowOwnerPID") == browser.pid}
    menu = [r for r in browser.ax() if r.get("AXRole") == "AXMenuItem" and r.get("AXTitle", "").lower().rstrip(".\u2026") in {"settings","preferences"}]
    if menu:
        browser.inspect("press", ",".join(map(str,menu[0]["path"])))
    else:
        act(key(",", "cmd"))
    time.sleep(1)
    after_windows = {w["kCGWindowNumber"] for w in helper("windows") if w.get("kCGWindowOwnerPID") == browser.pid}
    shot("settings", lambda: bool(after_windows-before_windows or browser.nodes("settings") or browser.nodes("preferences")))
    web_settings = [r for r in browser.ax() if r.get("AXRole") == "AXWebArea" and any(s in str(r.get("AXURL", "")) for s in ("chrome://settings", "about:preferences"))]
    if close_created_window(before_windows):
        pass
    elif web_settings:
        act(key("w", "cmd"))
    else:
        act(key("escape"))
    browser.activate()
    browser.page()
    act(key("t", "cmd")); time.sleep(.3)
    act(key("a", "cmd"),key("backspace")); time.sleep(.3); shot("new-tab")
    act(key("escape"))
    return result


def markdown(result):
    lines = [f"AX mode: {result.get('ax_mode', 'unspecified')}", "",
             "| Browser | Scenario | n | Action start ms med/p95 | Key to frame ms med/p95 | Paint ms med/p95 | Ready/full ms med/p95 | Settle ms med/p95 | Repeats med | Worst gap ms p95 |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    def fmt(value):
        return f"{value['median']:.1f}/{value['p95']:.1f}" if value else "-"
    for browser, data in result["browsers"].items():
        if data.get("status") in {"blocked", "skipped", "interrupted"}:
            lines.append(f"| {browser} | {data['status']}: {data['reason']} | 0 | - | - | - | - | - | - | - |")
        for name, entry in data.get("scenarios", {}).items():
            if entry.get("status") != "valid":
                lines.append(f"| {browser} | {name}: {entry.get('status', 'pending')} | {entry.get('n',0)} | - | - | - | - | - | - | - |")
                continue
            s = entry["summary"]
            ready = s.get("input_ready_ms") or s.get("first_full_frame_ms")
            lines.append(f"| {browser} | {name} | {entry['n']}/{len(entry['runs'])} | {fmt(s['first_change_ms'])} | {fmt(s.get('key_to_frame_ms'))} | {fmt(s['first_paint_ms'])} | {fmt(ready)} | {fmt(s['settled_ms'])} | {s['dropped_frames']['median']:.0f} | {s['worst_frame_gap_ms']['p95']:.1f} |")
    lines += ["", "60 Hz visible display capture. Latencies are quantized to about 16.7 ms. "
              "Settle means the last changed frame followed by at least 250 ms of stability. "
              "Repeated frames between visible changes are a dropped-frame proxy, not GPU telemetry. "
              "Ready/full is captured typed-text echo for Cmd+T, or a 97% match to the final full window for activation. "
              "Cmd+T text probes run every 50 ms, so OCR readiness is an upper-bound estimate. "
              "Input capture, browser response and recognition statuses are reported independently. "
              "n is accepted/attempted trials. Percentiles use accepted trials. "
              "Raw samples, min/max, standard deviation, validation evidence and rejection reasons are in the JSON.", ""]
    lines += ["| Browser | Fresh-process full window ms med/p95 | RSS MB 1/10/30 tabs | Physical MB 1/10/30 tabs | Idle CPU % | Background video CPU % | Scroll CPU % med | Scroll fps med/min |",
              "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for name, data in result["browsers"].items():
        r = data.get("resources", {})
        mem = r.get("memory", {})
        def memory(field):
            return "/".join(f"{mem[str(n)][field]:.1f}" if str(n) in mem else "-" for n in (1,10,30))
        def cpu(field):
            return f"{r[field]['percent']:.2f}" if "percent" in r.get(field, {}) else "-"
        scroll = data.get("scenarios",{}).get("scroll",{}).get("summary",{})
        scroll_cpu = scroll.get("cpu_percent")
        fps = scroll.get("observed_fps")
        cold_entry = data.get("cold_launch",{})
        cold = fmt(cold_entry.get("first_full_window_ms")) if cold_entry.get("status") == "valid" else "-"
        scroll_cpu_text = f"{scroll_cpu['median']:.2f}" if scroll_cpu else "-"
        fps_text = f"{fps['median']:.1f}/{fps['min']:.1f}" if fps else "-"
        lines.append(f"| {name} | {cold} | {memory('rss_mb')} | {memory('physical_mb')} | {cpu('idle_10_tabs')} | {cpu('background_video')} | {scroll_cpu_text} | {fps_text} |")
    launch_context = [
        f"- {name}: {data['cold_launch']['label']}."
        for name, data in result["browsers"].items()
        if data.get("cold_launch", {}).get("label")
    ]
    if launch_context:
        lines += ["", "Fresh-process timings use the JSON keys `cold_launch` and `first_full_window_ms`.", "", *launch_context]
    lines += ["", "| Browser | Scenario | Visually complete ms med/p95 | Frame interval ms median/p95/max | Intervals over 20 ms med |",
              "|---|---|---:|---:|---:|"]
    for browser,data in result["browsers"].items():
        for name,entry in data.get("scenarios",{}).items():
            s = entry.get("summary",{})
            if not s: continue
            interval = "/".join(f"{s[k]['median']:.1f}" for k in ("frame_interval_median_ms","frame_interval_p95_ms","frame_interval_max_ms") if s.get(k))
            lines.append(f"| {browser} | {name} | {fmt(s.get('visually_complete_ms'))} | {interval} | {s['frame_intervals_over_20ms']['median']:.0f} |")
    lines += ["", "| Browser | Command input capture | Browser readiness | Offline recognition |",
              "|---|---|---|---|"]
    for name, data in result["browsers"].items():
        command = data.get("scenarios", {}).get("command", {})
        counts = command.get("readiness_counts")
        if counts:
            values = ["; ".join(f"{key} {n}" for key, n in sorted(counts[field].items()))
                      for field in ("capture_status", "browser_status", "recognition")]
            lines.append("| " + " | ".join([name, *values]) + " |")
    return "\n".join(lines)+"\n"


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browsers", default="nook,arc,zen,chrome")
    parser.add_argument("--only", default=",".join(SCENARIOS+["cold", "resources", "shots"]),
                        help="comma-separated keyboard,click,command,navigate,close,sidebar,activate,link,scroll,cold,resources,shots; a-i also accepted")
    parser.add_argument("--nook-app", default="build/hillclimb/base/Nook.app")
    parser.add_argument("--label", default="base")
    parser.add_argument("--record-dir", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--phase", choices=("all", "preflight", "capture", "analyze"), default="all")
    parser.add_argument("--ax-mode", choices=("inspected", "none"), default="inspected",
                        help="none skips shared Arc and trials that need target-app accessibility")
    parser.add_argument("--max-load1", type=float, default=MAX_LOAD1)
    parser.add_argument("--lock-wait", type=float, default=LOCK_WAIT)
    parser.add_argument("--min-free-gib", type=float, default=CAPTURE_FREE_GIB)
    parser.add_argument("--ocr-timeout", type=float, default=OCR_TIMEOUT,
                        help="offline Vision deadline in seconds per readiness trial")
    parser.add_argument("--ocr-budget", type=float, default=OCR_BUDGET,
                        help="total offline Vision budget in seconds")
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--wait-build", type=int, default=1800)
    parser.add_argument("--helper-path", type=Path, help="use an existing executable capture helper instead of building the bundled helper")
    parser.add_argument("--helper-timeout", type=float, default=DEFAULT_HELPER_TIMEOUT,
                        help=f"helper command timeout in seconds, default: {DEFAULT_HELPER_TIMEOUT}; cold-launch capture retains its 15-second limit")
    parser.add_argument("--signposts", type=Path, help="stream Nook.Perf events as ndjson during this invocation")
    parser.add_argument("--sample-main", action="store_true", help="collect a 1 ms process stack sample alongside each recorded trial")
    parser.add_argument("--allow-arc-quit",action="store_true",help="explicitly allow graceful Arc restarts for cold launch and resource measurements; leave it running afterward")
    args = parser.parse_args(argv)
    for option in ("helper_timeout", "max_load1", "min_free_gib", "ocr_timeout", "ocr_budget", "lock_wait"):
        value = getattr(args, option)
        if not math.isfinite(value) or value < 0 or (value == 0 and option != "lock_wait"):
            parser.error(f"--{option.replace('_', '-')} must be finite and {'nonnegative' if option == 'lock_wait' else 'positive'}")
    if args.helper_path:
        args.helper_path = args.helper_path.expanduser().resolve()
        if not args.helper_path.is_file() or not os.access(args.helper_path, os.X_OK):
            parser.error("--helper-path must name an existing executable file")
    if args.runs < 10:
        parser.error("at least 10 repetitions are required")
    args.names = names = args.browsers.split(",")
    if set(names)-{"nook", "arc", "zen", "chrome"}:
        parser.error("unknown browser")
    only = {ALIASES.get(n, n) for n in args.only.split(",")}
    if "sidebar" in only:
        only.remove("sidebar"); only.update(("sidebar_show","sidebar_hide"))
    if only-set(SCENARIOS+["cold", "resources", "shots"]):
        parser.error("unknown scenario")
    args.only = only
    if args.out.suffix.lower() != ".json":
        parser.error("--out must name a .json evidence file")
    args.out = args.out.expanduser().resolve()
    args.preflight_path = args.out.with_name(args.out.stem+"-preflight.json")
    args.report_paths = (args.out.with_suffix(".md"), args.out.parent/"BLOCKERS.md")
    if args.report_paths[0].name.casefold() == args.report_paths[1].name.casefold():
        parser.error("--out must use a stem other than BLOCKERS")
    if args.record_dir:
        args.record_dir = args.record_dir.expanduser().resolve()
    if args.signposts:
        args.signposts = args.signposts.expanduser().resolve()
        if args.signposts in {args.out, args.preflight_path, *args.report_paths}:
            parser.error("--signposts must have a separate output path")
    args.nook_app = Path(args.nook_app).expanduser().resolve()
    if args.phase != "analyze" and "nook" in names:
        if args.nook_app.is_relative_to(Path("/Applications").resolve()):
            parser.error("--nook-app must be an isolated build outside /Applications")
    return args


def new_result(args):
    return {"label": args.label, "when": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
              "method": {"fps": 60, "sample_grid": [160,100], "change_fraction": .0015,
                         "pixel_rgb_delta": 30, "settle_guard_ms": 250,
                         "capture": "ScreenCaptureKit full-display buffer, explicit crop, cursor excluded; activation retains the full display",
                         "visually_complete": "last frame changing more than 0.5% of verified window pixels at RGB delta > 30",
                         "regions": "first matching region wins; rectangles use global top-left display coordinates; outside includes the entire captured display",
                         "frame_intervals": "time between changed presentations during the first 3 seconds of scroll input",
                         "resolution": "window in logical pixels for timings; display-native pixels for still screenshots",
                         "launcher": "LaunchServices launches new instances. Regular Arc measurements reuse its existing instance when available.",
                         "dropped_frames": "60 Hz repeated refresh slots between changed frames during motion",
                         "cpu": "kernel process Mach ticks converted with mach_timebase_info / wall seconds, 100% is one core",
                         "footprint": "proc_pid_rusage RUSAGE_INFO_V4, descendants plus responsible PID helpers",
                         "action_start": "host monotonic time before modifier and key dispatch",
                         "key_to_frame": "target CGEvent key-down timestamp to the first changed frame",
                         "input_ready": "cropped 50 ms text probes, with offline Vision and a separate local URL beacon"},
              "ax_mode": args.ax_mode, "isolation_manifest": isolation_manifest(args.names),
              "preflight": {}, "browsers": {}, "blockers": []}


def save_result(args, result):
    summary_path, blockers_path = args.report_paths
    write_json(args.out, result)
    write_atomic(summary_path, lambda stream: stream.write(markdown(result)))
    blockers = "# UI benchmark blockers and discarded measurements\n\n"
    blockers += "".join(f"- {item}\n" for item in result["blockers"])
    write_atomic(blockers_path, lambda stream: stream.write(blockers))


def prepare_helper(args):
    if not args.helper_path and (not HELPER.exists() or HELPER.stat().st_mtime < SOURCE.stat().st_mtime):
        HELPER.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".uibench-build-", dir=HELPER.parent) as directory:
            binary = Path(directory)/HELPER.name
            run(["swiftc", "-O", "-parse-as-library", SOURCE, "-o", binary], timeout=120)
            binary.replace(HELPER)


def desktop_preflight(args, result, output_paths, space_paths):
    report = result["preflight"]
    report["experiment_lock"] = "acquired"
    report["volumes"] = disk_headroom(space_paths, args.min_free_gib)
    check_evidence(output_paths)
    report["evidence_writable"] = True
    prepare_helper(args)
    try:
        permissions = helper("permissions")
    except (Invalid, subprocess.TimeoutExpired, OSError, ValueError) as error:
        raise Invalid(f"permission probe failed for {HELPER}: {error}") from error
    result["permissions"] = permissions
    if permissions.get("console_session") is False:
        raise Invalid("no active macOS console session; run from the logged-in desktop user")
    if permissions.get("unlocked") is False:
        raise Invalid("macOS desktop is locked; unlock it before running capture")
    required = {"unlocked": "active desktop session", "screen": "Screen Recording",
                "post_events": "synthetic input (Accessibility)"}
    if args.ax_mode == "inspected":
        required["accessibility"] = "Accessibility"
    missing = [label for field, label in required.items() if permissions.get(field) is not True]
    if missing:
        raise Invalid(f"macOS permission missing for {HELPER}: {', '.join(missing)}. Check the runner's permission profile.")
    if permissions.get("capture_protocol") != 3:
        raise Invalid("capture helper uses an incompatible evidence protocol; rebuild it from uibench_capture.swift")
    try:
        pid = os.getpid()
        if pid not in processes():
            raise Invalid("ps could not identify the runner")
        OwnedProcess(pid).identify()
        if "physical_bytes" not in helper("footprint", pid).get(str(pid), {}):
            raise Invalid("kernel footprint query was denied")
        if not isinstance(helper("windows"), list):
            raise Invalid("Window Server did not return a window list")
    except (Invalid, subprocess.TimeoutExpired, OSError, ValueError) as error:
        raise Invalid(f"process or Window Server inspection failed; check the runner's permission profile: {error}") from error
    report["process_inspection"] = True


def summarize_scenario(entry, runs):
    valid = [trial for trial in entry["runs"] if trial["status"] == "valid"]
    entry["n"] = len(valid)
    entry["status"] = "valid" if len(valid) >= runs else "discarded"
    if entry["status"] == "valid":
        fields = set().union(*(trial.keys() for trial in valid)) - {"raw", "status"}
        entry["summary"] = {field: summary([trial.get(field) for trial in valid]) for field in sorted(fields)}
    else:
        reasons = sorted({trial["reason"] for trial in entry["runs"] if "reason" in trial})
        entry["reason"] = "; ".join(reasons) or "fewer than the requested validated repetitions"


def collect_scenarios(args, data, browser, record):
    for name in SCENARIOS:
        if name not in args.only:
            continue
        if args.ax_mode == "none" and name in AX_ONLY_SCENARIOS:
            data["scenarios"][name] = {"status": "skipped", "reason": "requires target-app AX controls"}
            continue
        entry = data["scenarios"][name] = {"runs": []}
        log(f"{browser.name}: {name}, {args.runs} repetitions")
        for index in range(args.runs*2):
            trial = {"status": "pending"}
            entry["runs"].append(trial)
            with browser.evidence.attach(trial):
                try:
                    directory = record/name/f"{index+1:02d}" if record else None
                    trial.update(scenario(browser, name, index, directory))
                except InstrumentationUnavailable as error:
                    trial.update(status="discarded", failure_stage="instrumentation", reason=str(error))
                except (Invalid, subprocess.TimeoutExpired, OSError) as error:
                    trial.update(status="discarded", reason=str(error))
                    # An unsupported control cannot yield the requested repetitions.
                    if index == 0 and any(reason in str(error) for reason in (
                        "no comparable", "no visible accessible control", "foreground application",
                    )):
                        break
            if sum(trial["status"] == "valid" for trial in entry["runs"]) >= args.runs:
                break
        summarize_scenario(entry, args.runs)


def collect_browser(args, name, path, data, result, calibrated, evidence):
    if args.ax_mode == "none" and name == "arc":
        data.update(status="skipped", reason="Arc's existing tabs require AX ownership checks")
        return calibrated
    record = args.record_dir/name if args.record_dir else None
    shots = args.out.parent/"shots"/name
    browser = None
    restart_arc = args.allow_arc_quit and name == "arc"
    with evidence.attach(data):
        try:
            if "cold" in args.only:
                log(f"{name}: {args.runs} launch trials. {launch_label(name)}.")
                entry = data["cold_launch"] = {"status": "pending"}
                with evidence.attach(entry):
                    cold_launch(name, path, args.runs, record/"cold" if record else None,
                                args.allow_arc_quit, evidence=evidence, entry=entry)
                if entry["status"] != "valid":
                    result["blockers"].append(f"{name} cold: {entry.get('reason', 'too few validated cold trials')}")
                if restart_arc:
                    data["left_running_pid"] = leave_arc_running(path)
            if not args.only - {"cold"} or (args.ax_mode == "none" and not args.only - (AX_ONLY_SCENARIOS | {"cold"})):
                for scenario_name in args.only & set(SCENARIOS):
                    data["scenarios"][scenario_name] = {"status": "skipped", "reason": "requires target-app AX controls"}
                for field in args.only & {"shots", "resources"}:
                    data[field] = {"status": "skipped", "reason": "requires target-app AX controls"}
                data["status"] = "captured"
                return calibrated
            log(f"{name}: opening benchmark session")
            browser = Browser(name, path, evidence)
            browser.sample_main = args.sample_main
            browser.launch()
            data.update(version=browser.version, pid=browser.pid, profile={
                "arc": "persistent Arc profile",
                "nook": "temporary tab state and persistent bundle data",
                "chrome": "temporary user data directory",
                "zen": "temporary profile",
            }[name])
            if not calibrated:
                trial = data["validation"] = {"status": "pending"}
                with evidence.attach(trial):
                    trial.update(validation(browser, record/"calibration" if record else None))
                calibrated = True
                log(f"{name}: synthetic capture calibration passed")
            if args.only & set(SCENARIOS):
                browser.page(new=name != "zen")
                collect_scenarios(args, data, browser, record)
            for label, action in (("shots", lambda: screenshots(browser, shots)),
                                  ("resources", lambda: resource_scenarios(browser, args.allow_arc_quit))):
                if label not in args.only:
                    continue
                if args.ax_mode == "none":
                    data[label] = {"status": "skipped", "reason": "requires target-app AX controls"}
                    continue
                if name != "arc" or (label == "resources" and restart_arc):
                    browser.cleanup()
                    if name == "arc":
                        quit_arc(path)
                        leave_arc_running(path)
                    browser = Browser(name, path, evidence)
                    browser.launch()
                try:
                    data[label] = action()
                except (Invalid, subprocess.TimeoutExpired, OSError) as error:
                    data[label] = {"status": "discarded", "reason": str(error)}
                    result["blockers"].append(f"{name} {label}: {error}")
            data["status"] = "captured"
        except (Invalid, OSError, subprocess.TimeoutExpired) as error:
            data.update(status="blocked", reason=str(error))
            result["blockers"].append(f"{name}: {error}")
            log(f"{name}: blocked: {error}")
        finally:
            with finish_on_interrupt():
                if browser:
                    try:
                        browser.cleanup()
                    except (Invalid, OSError, subprocess.TimeoutExpired) as error:
                        browser.cleanup_error = str(error)
                    if getattr(browser, "cleanup_error", None):
                        data["cleanup_error"] = browser.cleanup_error
                        result["blockers"].append(f"{name} cleanup: {browser.cleanup_error}")
                if restart_arc and Path(path).exists():
                    try:
                        data["left_running_pid"] = leave_arc_running(path)
                    except (Invalid, OSError, subprocess.TimeoutExpired) as error:
                        result["blockers"].append(f"{name} relaunch: {error}")
    return calibrated


def capture_desktop(args, result, evidence):
    paths = {"nook": args.nook_app, "arc": "/Applications/Arc.app", "zen": "/Applications/Zen.app",
             "chrome": "/Applications/Google Chrome.app"}
    calibrated = False
    trace = trace_reader = None
    trace_data = bytearray()
    trace_limit = 64 * 1024**2
    trace_truncated = False

    def read_trace(pipe):
        nonlocal trace_truncated
        with pipe:
            while chunk := pipe.read1(64 * 1024):
                room = max(0, trace_limit - len(trace_data))
                trace_data.extend(chunk[:room])
                trace_truncated |= len(chunk) > room

    server = bench.DualStackServer(("::", bench.PORT), Handler)
    server.daemon_threads = True
    Handler.events.clear()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        if args.signposts:
            with finish_on_interrupt():
                trace = subprocess.Popen(
                    ["/usr/bin/log", "stream", "--signpost", "--level", "debug", "--style", "ndjson",
                     "--predicate", 'subsystem == "Nook.Perf"'],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                )
                trace_reader = threading.Thread(target=read_trace, args=(trace.stdout,), daemon=True)
                trace_reader.start()
            time.sleep(.5)
            if trace.poll() is not None:
                raise Invalid("signpost stream exited before launch")
        settings = (("com.apple.WindowManager", "GloballyEnabled"),
                    ("NSGlobalDomain", "NSAutomaticWindowAnimationsEnabled"),
                    ("com.apple.universalaccess", "reduceMotion"),
                    ("com.apple.universalaccess", "reduceTransparency"))
        result["desktop_settings"] = {
            f"{domain}.{key}": subprocess.run(["defaults", "read", domain, key], capture_output=True,
                                              text=True, timeout=5).stdout.strip()
            for domain, key in settings
        }
        result["os_version"] = run(["sw_vers"]).strip()
        result["load1"] = check_load(args.max_load1)
        result["preflight"]["status"] = "ready"
        for name in args.names:
            data = result["browsers"][name] = {"scenarios": {}}
            try:
                calibrated = collect_browser(args, name, paths[name], data, result, calibrated, evidence)
            finally:
                # The browser and its throwaway profile are gone before either write.
                with finish_on_interrupt():
                    for scenario_name, entry in data["scenarios"].items():
                        if entry.get("status") == "discarded":
                            result["blockers"].append(f"{name} {scenario_name}: {entry['reason']}")
                    write_json(args.out, result)
                    if errors := evidence.flush():
                        result.setdefault("artifact_errors", {}).update(errors)
                        write_json(args.out, result)
    finally:
        with finish_on_interrupt():
            try:
                if trace:
                    if trace.poll() is None:
                        trace.terminate()
                        try:
                            trace.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            trace.kill()
                            trace.wait(timeout=5)
                    if trace_reader:
                        trace_reader.join(timeout=5)
                    if trace_truncated:
                        result["blockers"].append("signposts reached the 64 MiB in-memory limit")
                    if trace_reader and trace_reader.is_alive():
                        result["blockers"].append("signpost reader did not drain within five seconds")
                    try:
                        saved_trace = bytes(trace_data)
                        length = saved_trace.rfind(b"\n") + 1
                        write_atomic(args.signposts, lambda stream: stream.write(saved_trace[:length]), "wb")
                    except OSError as error:
                        result.setdefault("artifact_errors", {})[str(args.signposts)] = str(error)
            finally:
                server.shutdown()
                server.server_close()
                bench.forget_favicons([bench.PORT])


def offline_analysis(args, result):
    deadline = time.monotonic() + args.ocr_budget
    for data in result["browsers"].values():
        for name, entry in data.get("scenarios", {}).items():
            for trial in entry.get("runs", []):
                raw = trial.get("raw")
                if raw is None:
                    continue
                try:
                    validate_timeline(raw)
                    raw["timestamp_validation"] = "valid"
                except (Invalid, KeyError, TypeError, ValueError) as error:
                    raw["timestamp_validation"] = str(error)
                    trial.update(status="discarded", failure_stage="timing", reason=str(error))
                    continue
                readiness = raw.get("readiness")
                if name != "command" or not readiness:
                    continue
                trial.pop("input_ready_ms", None)
                trial.pop("input_ready_key_to_frame_ms", None)
                remaining = deadline - time.monotonic()
                if remaining <= 0 and readiness["capture_status"] == "captured":
                    readiness["recognition"] = {"status": "budget_exhausted", "reason": "offline Vision budget elapsed"}
                    continue
                recognition = readiness["recognition"] = recognize_input(
                    readiness, lambda path: helper("ocr", path, timeout=min(args.ocr_timeout, remaining)),
                    root=args.out.parent,
                )
                if recognition["status"] == "matched" and readiness["browser_status"] == "responsive":
                    trial["input_ready_ms"] = recognition["action_start_ms"]
                    if "key_to_frame_ms" in recognition:
                        trial["input_ready_key_to_frame_ms"] = recognition["key_to_frame_ms"]
            if entry.get("runs"):
                summarize_scenario(entry, result.get("requested_runs", args.runs))
                if name == "command":
                    update_readiness_counts(entry)
    result["analysis_status"] = "complete"


def update_readiness_counts(entry):
    trials = [trial.get("raw", {}).get("readiness", {}) for trial in entry["runs"]]
    entry["readiness_counts"] = {
        field: dict(Counter(trial.get(field, "unavailable") for trial in trials))
        for field in ("capture_status", "browser_status")
    }
    entry["readiness_counts"]["recognition"] = dict(
        Counter(trial.get("recognition", {}).get("status", "unavailable") for trial in trials)
    )


def wait_for_build(args):
    exe = Path(args.nook_app)/"Contents/MacOS/Nook"
    if exe.exists():
        return
    deadline = time.monotonic()+args.wait_build
    log(f"waiting for isolated Nook build at {exe}")
    while not exe.exists() and time.monotonic() < deadline:
        time.sleep(min(5, max(0, deadline-time.monotonic())))


def run_phases(args):
    result = new_result(args)
    result["requested_runs"] = args.runs
    evidence = Evidence(args.out.with_name(args.out.stem+"-evidence"), args.ax_mode)
    preflight_path = args.preflight_path
    output_paths = [args.out, *args.report_paths, preflight_path, evidence.folder.parent/"crop.json"]
    if "shots" in args.only and args.ax_mode == "inspected":
        output_paths.append(args.out.parent/"shots"/"capture.png")
    if args.record_dir:
        output_paths.append(args.record_dir/"capture.png")
    if args.signposts:
        output_paths.append(args.signposts)
    space_paths = [*output_paths, HELPER, tempfile.gettempdir()]
    if "resources" in args.only and args.ax_mode == "inspected":
        space_paths.append(VIDEO)
    if args.phase == "analyze":
        with exclusive(args.lock_wait, log):
            result = json.loads(args.out.read_text())
            if result.get("capture_status") not in {"complete", "interrupted"}:
                raise Invalid("the evidence file does not contain a finished or interrupted capture")
            check_evidence([args.out, *args.report_paths])
            prepare_helper(args)
            offline_analysis(args, result)
            save_result(args, result)
    else:
        # Reject low space even when another experiment owns the lock.
        disk_headroom(space_paths, args.min_free_gib)
        while True:
            with exclusive(args.lock_wait, log):
                try:
                    desktop_preflight(args, result, output_paths, space_paths)
                    if args.phase == "preflight":
                        result["load1"] = check_load(args.max_load1)
                        result["preflight"]["status"] = "ready"
                        write_json(preflight_path, result)
                        log(f"desktop preflight ready; report at {preflight_path}")
                        return 0
                    needs_build = "nook" in args.names and not (Path(args.nook_app)/"Contents/MacOS/Nook").exists()
                    if not needs_build:
                        if "resources" in args.only and args.ax_mode == "inspected" and not VIDEO.exists():
                            VIDEO.parent.mkdir(parents=True, exist_ok=True)
                            helper("video", VIDEO)
                        result["capture_status"] = "running"
                        capture_desktop(args, result, evidence)
                        result["capture_status"] = "complete"
                        result["analysis_status"] = "pending"
                        for data in result["browsers"].values():
                            if "runs" in (entry := data.get("scenarios", {}).get("command", {})):
                                update_readiness_counts(entry)
                        save_result(args, result)
                        if args.phase == "all":
                            offline_analysis(args, result)
                            save_result(args, result)
                        break
                    if args.wait_build <= 0:
                        raise Invalid("isolated Nook build did not appear before the wait deadline")
                except Interrupted:
                    if result.get("capture_status") == "running":
                        result["capture_status"] = "interrupted"
                        with finish_on_interrupt():
                            save_result(args, result)
                    raise
                except (Invalid, OSError, subprocess.TimeoutExpired, ValueError) as error:
                    result["blockers"].append(str(error))
                    if result.get("capture_status") != "complete":
                        result["capture_status"] = "blocked"
                    if result["preflight"].get("status") != "ready":
                        result["preflight"].update(status="blocked", reason=str(error))
                        result["browsers"] = {name: {"status": "blocked", "reason": str(error)} for name in args.names}
                    log(str(error))
                    if args.phase == "preflight" or (args.out.exists() and result["preflight"].get("status") == "blocked"):
                        write_json(preflight_path, result)
                    else:
                        save_result(args, result)
                    return 1
            # The coordinated build may need the same lock while we wait.
            wait_for_build(args)
            args.wait_build = 0
    print(markdown(result))
    return 0


def main(argv=None):
    global HELPER, HELPER_TIMEOUT
    args = parse_args(argv)
    HELPER = args.helper_path or BUNDLED_HELPER
    HELPER_TIMEOUT = args.helper_timeout
    try:
        with cooperative_signals():
            return run_phases(args)
    except Interrupted as error:
        log(str(error))
        return 128 + error.signum
    except (Invalid, OSError, subprocess.TimeoutExpired, ValueError) as error:
        log(str(error))
        return 1


if __name__ == "__main__":
    sys.exit(main())
