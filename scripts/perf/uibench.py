#!/usr/bin/env python3
"""Compare native browser UI from visible, timestamped 60 Hz display capture.

Requires macOS Screen Recording and Accessibility permissions. Uses only Python's
standard library and a Swift helper, built into build/hillclimb/bin on demand.
No browser automation protocol supplies the latency measurements.
"""
import argparse
import base64
import ctypes
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid

import bench

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name("uibench_capture.swift")
HELPER = ROOT / "build/hillclimb/bin/uibench-capture"
SCENARIOS = ["keyboard", "click", "command", "navigate", "close", "sidebar_hide", "sidebar_show", "activate", "link", "scroll"]
ALIASES = dict(zip("abcdefghi", ["keyboard","click","command","navigate","close","sidebar_hide","activate","link","scroll"]))
COLORS = {"red": "#bd3645", "blue": "#285ea8", "green": "#269454"}
KEYS = {"t": 17, "w": 13, "l": 37, "s": 1, "f": 3, "j": 38, "a": 0,
        "return": 36, "escape": 53, "tab": 48, "home": 115, "backspace":51, ",": 43}


class Invalid(RuntimeError):
    pass


class ForeignWindow(Invalid):
    pass


def visible_obstructions(pid, rows):
    """CGWindow rows are ordered front to back; only windows ahead can cover us."""
    target = next((i for i, row in enumerate(rows)
                   if row.get("kCGWindowOwnerPID") == pid and row.get("kCGWindowLayer") == 0
                   and row["kCGWindowBounds"]["Width"] > 300
                   and row["kCGWindowBounds"]["Height"] > 300), None)
    if target is None:
        raise Invalid("benchmark window is not on screen")
    bounds = rows[target]["kCGWindowBounds"]
    def overlaps(other):
        return (min(bounds["X"]+bounds["Width"], other["X"]+other["Width"]) > max(bounds["X"], other["X"])
                and min(bounds["Y"]+bounds["Height"], other["Y"]+other["Height"]) > max(bounds["Y"], other["Y"]))
    return [row for row in rows[:target] if row.get("kCGWindowOwnerPID") != pid
            and row.get("kCGWindowOwnerName") != "Wispr Flow"
            # ScreenCaptureKit excludes the cursor from these captures.
            and not (row.get("kCGWindowOwnerName") == "Window Server"
                     and row.get("kCGWindowName") == "Cursor"
                     and row.get("kCGWindowLayer") == 2147483630)
            and row.get("kCGWindowAlpha", 1) > 0 and overlaps(row["kCGWindowBounds"])]


def reject_obstruction(pid):
    obstructions = visible_obstructions(pid, helper("windows"))
    if obstructions:
        identities = [(r.get("kCGWindowOwnerPID"), r.get("kCGWindowOwnerName"),
                       r.get("kCGWindowBounds")) for r in obstructions]
        raise ForeignWindow(f"foreign window overlaps the benchmark window: {identities}")


class OwnedProcess:
    """A responsibility-isolated child spawned by the native helper."""
    def __init__(self, pid):
        self.pid = pid
        self.identity = run(["ps","-p",pid,"-o","lstart=,comm="]).strip()

    def poll(self):
        identity = subprocess.run(["ps","-p",str(self.pid),"-o","lstart=,comm="], capture_output=True, text=True).stdout.strip()
        return None if identity and identity == self.identity else 0

    def terminate(self):
        if self.poll() is None:
            os.kill(self.pid,15)

    def kill(self):
        if self.poll() is None:
            os.kill(self.pid,9)

    def wait(self, timeout=10):
        end = time.monotonic()+timeout
        while self.poll() is None and time.monotonic() < end:
            time.sleep(.1)
        if self.poll() is None:
            raise subprocess.TimeoutExpired("browser",timeout)


def log(text):
    print(text, file=sys.stderr, flush=True)


def run(args, timeout=40):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise Invalid(f"{Path(str(args[0])).name}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def helper(command, *args):
    result = json.loads(run([HELPER, command, *args]))
    if isinstance(result, dict) and result.get("error"):
        raise Invalid(result["error"])
    return result


def spec_call(command, spec):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as f:
        json.dump(spec, f); f.flush()
        return helper(command, f.name)


def key(name, *flags, at=0.5):
    return {"kind": "key", "code": KEYS[name], "flags": list(flags), "at": at}


def scroll_actions():
    """Three seconds of phased, continuous pixel input at 120 Hz, 1440 px/s."""
    return ([{"kind":"scroll", "dy":0, "phase":1, "at":.5}] +
            [{"kind":"scroll", "dy":-12, "phase":2, "at":.5+i/120} for i in range(1,361)] +
            [{"kind":"scroll", "dy":0, "phase":4, "at":3.5+1/120}])


# The browser the benchmark launched; keyboard events are dropped unless it holds focus.
KEYBOARD_OWNER = None


def guarded(actions):
    return [{**a, "guard": KEYBOARD_OWNER} if KEYBOARD_OWNER and a.get("kind") in ("key", "text", "click", "move", "scroll") else a for a in actions]


def act(*actions):
    if KEYBOARD_OWNER and any(a.get("kind") in {"key", "text", "click", "scroll"} for a in actions):
        reject_obstruction(KEYBOARD_OWNER)
    return spec_call("action", guarded(actions))


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


def window(pid):
    return next((w for w in helper("windows") if w.get("kCGWindowOwnerPID") == pid
                 and w.get("kCGWindowLayer") == 0 and w["kCGWindowBounds"]["Width"] > 300
                 and w["kCGWindowBounds"]["Height"] > 300), None)


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


def capture(pid, actions=(), duration=2, record=None, ocr=None, signatures=False, native=False, region=None, attribution=None):
    if not (attribution or {}).get("full_display"):
        reject_obstruction(pid)
    visible = window(pid)
    result = spec_call("capture", {"pid": pid, "window_id": visible["kCGWindowNumber"] if visible else None,
                                   "actions": guarded(actions), "duration": duration, "ocr_needle":ocr,"signatures":signatures,
                                   "region":region,
                                   "native_resolution":native, **(attribution or {}),
                                   **({"record_dir": str(record)} if record else {})})
    if not (attribution or {}).get("full_display"):
        try:
            reject_obstruction(pid)
        except ForeignWindow:
            if record:
                for path in Path(record).glob("*.png"):
                    path.unlink()
            raise
    if len([f for f in result["frames"] if "changed" in f]) < (2 if actions else 1):
        raise Invalid("capture delivered too few complete frames")
    result["record_dir"] = str(Path(record).resolve()) if record else None
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
    t0 = raw["events"][0]["t"]
    complete = [f for f in raw["frames"] if "changed" in f]
    before = [f for f in complete if f["t"] < t0]
    if not before:
        raise Invalid("no pre-input reference frame")
    post = [f for f in complete if f["t"] >= t0]
    changed = [f for f in post if f["changed"] >= .0015]
    if not changed:
        raise Invalid("no visible response to input")
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
    return {"first_change_ms": (changed[0]["t"]-t0)*1000,
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
            video = ROOT / "build/hillclimb/bin/loop.mp4"
            return self.reply("video/mp4", video.read_bytes()) if video.exists() else self.reply("text/plain", "unavailable", 404)
        q = urllib.parse.parse_qs(url.query)
        ident = q.get("id", ["unknown"])[0]
        color = q.get("color", ["red"])[0]
        dest = f"/ui/page?color=blue&id={ident}-next"
        extra = ""
        if kind == "long":
            # Real English avoids browser translation offers for placeholder Latin.
            words = "This local page repeats colored rows so the benchmark can measure smooth continuous scrolling and track each displayed frame precisely."
            extra = "".join(f"<section style='height:120px;background:hsl({i*31%360},65%,40%)'>Row {i}: {words}</section>" for i in range(600))
        if kind == "video":
            extra = """<button onclick="document.querySelector('video').play()">Start local video</button><br>
            <video autoplay muted loop playsinline controls width=640 src='/ui/video.mp4'></video>
            <script>setInterval(()=>{let v=document.querySelector('video');navigator.sendBeacon('/ui-event',JSON.stringify({
            id:new URLSearchParams(location.search).get('id'),kind:'video',wall:Date.now(),
            current:v.currentTime,paused:v.paused,hidden:document.hidden,ready:v.readyState}));},500)</script>"""
        script = ""
        if kind == "long":
            script = """let tracing=false, frames=[], wheel=[];
            addEventListener('wheel',e=>wheel.push([performance.now(),e.deltaY,e.deltaMode]),{passive:true});
            addEventListener('scroll',()=>{if(tracing)return;tracing=true;
              function tick(t){frames.push([t,scrollY]);if(frames.length<240)requestAnimationFrame(tick);
              else navigator.sendBeacon('/ui-event',JSON.stringify({id:ID,kind:'scrolltrace',wall:Date.now(),origin:performance.timeOrigin,frames,wheel,
                sectionTop:document.querySelector('section').offsetTop,sectionHeight:document.querySelector('section').offsetHeight,
                viewport:[innerWidth,innerHeight],dpr:devicePixelRatio}));}
              requestAnimationFrame(tick);},{passive:true});"""
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
        window.onload=()=>navigator.sendBeacon('/ui-event',JSON.stringify({id:ID,kind:'load',wall:Date.now()}));
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
    def __init__(self, name, path):
        self.name, self.path = name, Path(path).resolve()
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
                    "-ApplePersistenceIgnoreState","YES", "-settings.hideWebContentBorder", os.environ.get("M3_HIDE_BORDER","NO"), "-settings.showLinkStatusBar", os.environ.get("M3_LINK_STATUS","YES")]
            launched = spec_call("launch",{"app":str(self.path),"args":args})
            if launched["pid"] in initial:
                raise Invalid("launch reused a pre-existing instance; refusing to drive or terminate it")
            self.launch_time = launched["start"]
            self.proc = self.app.proc = OwnedProcess(launched["pid"])
            self.pid = self.proc.pid
            token = Path.home()/"Library/Application Support"/self.bundle/"dev-mcp-token"
            self.app.token = token.read_text().strip() if token.exists() else None
        elif not self.pid:
            args = [str(self.exe)]
            if self.name == "chrome":
                args += [f"--user-data-dir={self.temp.name}", "--no-first-run", "--no-default-browser-check"]
            if self.name == "zen":
                (Path(self.temp.name)/"user.js").write_text('user_pref("browser.shell.checkDefaultBrowser", false);\nuser_pref("zen.welcome-screen.seen", true);\nuser_pref("browser.startup.homepage_override.mstone", "ignore");\n')
                args += ["-profile", self.temp.name, "-no-remote", "-new-instance"]
            launched = spec_call("launch",{"app":str(self.path),"args":args})
            if launched["pid"] in initial:
                raise Invalid("launch reused a pre-existing instance; refusing to drive or terminate it")
            self.launch_time = launched["start"]
            self.proc = OwnedProcess(launched["pid"])
            self.pid = self.proc.pid
        global KEYBOARD_OWNER
        KEYBOARD_OWNER = self.pid
        deadline = time.monotonic() + 30
        self.activate()
        if self.name == "arc":
            time.sleep(.5)
            if not window(self.pid):
                act({"kind":"key", "code":45, "flags":["cmd"]})
        while not window(self.pid) and time.monotonic() < deadline:
            time.sleep(.2)
        if not window(self.pid):
            raise Invalid("no browser window within 30 seconds; onboarding or launch blocked")
        if normalize:
            if self.name == "arc":
                self.original_bounds = window(self.pid)["kCGWindowBounds"]
            helper("resize", self.pid)
            time.sleep(1)
        self.activate()
        if self.name == "arc" and prepare:
            self.close_library()
            self.navigate(self.url()[0], new=True)

    def close_library(self):
        if self.name != "arc":
            return
        menu = [r for r in self.ax() if r.get("AXRole") == "AXMenuItem" and r.get("AXTitle") == "Close Library"]
        if menu:
            helper("press", self.pid, ",".join(map(str,menu[0]["path"])))
            time.sleep(.3)

    def activate(self):
        act({"kind": "activate", "pid": self.pid})
        time.sleep(.15)

    def ax(self):
        return helper("ax", self.pid)

    def url(self, color="red", kind="page", ident=None):
        ident = ident or f"{self.session}-{uuid.uuid4().hex[:8]}"
        return f"{bench.HOST}/ui/{kind}?color={color}&id={ident}", ident

    def navigate(self, url, new=False):
        self.activate()
        if helper("front")["pid"] != self.pid:
            raise Invalid("browser did not become the foreground application")
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
        rows = helper("ax-focused", self.pid)
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
            helper("press",self.pid,",".join(map(str,row["path"])))
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
        if self.closed:
            return
        self.closed = True
        if self.name == "arc" and self.pid:
            # Close only explicitly-created local benchmark tabs, selected by AX.
            self.activate()
            self.close_library()
            for _ in range(self.owned_tabs+3):
                tabs = self.nodes(f"UIBENCH {self.session}-", {"AXRadioButton", "AXTab", "AXButton"})
                tabs = [r for r in tabs if r.get("rect", [0,0,9999])[2] < 500]
                if not tabs:
                    break
                try:
                    self.select_owned_tab(tabs[0]); self.close_tab(); time.sleep(.15)
                except Invalid as error:
                    self.cleanup_error = str(error)
                    log(f"Arc cleanup stopped: {error}")
                    break
            if self.original_bounds:
                helper("resize", self.pid, *[self.original_bounds[k] for k in ("X","Y","Width","Height")])
        if self.proc and self.proc.poll() is None:
            if self.name == "arc":
                quit_arc(self.path)
                self.proc = None
                self.temp.cleanup()
                return
            # Descendants and responsible helpers were verified against this root.
            ids = self.pids()
            self.proc.terminate()
            try:
                self.proc.wait(8)
            except subprocess.TimeoutExpired:
                self.proc.kill(); self.proc.wait()
            for pid in ids:
                if pid == self.pid:
                    continue
                try:
                    os.kill(pid, 15)
                except ProcessLookupError:
                    pass
        self.temp.cleanup()


def validation(browser, record):
    ident = browser.page(kind="validate")
    w = window(browser.pid)["kCGWindowBounds"]
    raw = capture(browser.pid, [{"kind": "click", "x": w["X"]+w["Width"]*.7,
                                "y": w["Y"]+w["Height"]*.7, "at": .5}], 2, record)
    event = Handler.events.get((ident, "color"))
    if not event:
        raise Invalid("synthetic color-change beacon missing")
    # Python's monotonic clock includes sleep on macOS; capture uses host time.
    clock = raw["clock"]
    known = event["wall"]/1000 + clock["host_seconds"] - clock["wall_seconds"]
    first = next((f["t"] for f in raw["frames"] if f.get("green", 0) > .2), None)
    delta = (first-known)*1000 if first else None
    delay = (known-raw["events"][0]["t"])*1000
    if delta is None or not -20 <= delta <= 100 or not 450 <= delay <= 650:
        raise Invalid(f"synthetic calibration failed: capture error {delta} ms, scheduled delay {delay:.1f} ms")
    return {"status": "valid", "scheduled_delay_ms": 500, "observed_page_delay_ms": delay,
            "capture_after_known_change_ms": delta, "raw": raw}


def cold_launch(name, path, runs, record, allow_arc_quit=False):
    if name == "arc" and not allow_arc_quit:
        return {"status":"discarded", "reason":"Arc has no profile flag and its existing instance must remain running"}
    samples = []
    for index in range(runs):
        if name == "arc":
            quit_arc(path)
        browser = Browser(name, path)
        with tempfile.TemporaryDirectory(prefix="uibench-cold-") as temporary:
            ready = Path(temporary)/"ready"
            spec = {"duration":8, "signatures":True, "ready_file":str(ready)}
            if record:
                spec["record_dir"] = str(record/f"{index+1:02d}")
            specpath = Path(temporary)/"spec.json"; specpath.write_text(json.dumps(spec))
            process = subprocess.Popen([str(HELPER), "capture", str(specpath)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic()+10
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                if not ready.exists():
                    raise Invalid("pre-launch capture never became ready")
                time.sleep(.25)
                browser.launch(normalize=False,prepare=False)
                start = browser.launch_time
                output, errors = process.communicate(timeout=15)
                if process.returncode:
                    raise Invalid(errors or output)
                raw = json.loads(output)
                w = window(browser.pid)
                if not w:
                    raise Invalid("cold launch ended without a visible window")
                bounds = w["kCGWindowBounds"]
                x0,y0,width,height = raw["rect"]
                cells = [(y*160+x)*3 for y in range(100) for x in range(160)
                         if bounds["X"]+10 <= x0+x*width/160 < bounds["X"]+bounds["Width"]-10
                         and bounds["Y"]+40 <= y0+y*height/100 < bounds["Y"]+bounds["Height"]-10]
                frames = [f for f in raw["frames"] if "pixels" in f]
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
                samples.append({"status":"valid", "first_full_window_ms":(matches[0]-start)*1000,
                                "raw":raw, "reference_rect":bounds})
            except (Invalid, subprocess.TimeoutExpired) as error:
                samples.append({"status":"discarded", "reason":str(error)})
            finally:
                if process.poll() is None:
                    process.terminate(); process.communicate(timeout=5)
                browser.cleanup()
    valid = [s["first_full_window_ms"] for s in samples if s["status"] == "valid"]
    return {"status":"valid" if len(valid) >= 10 else "discarded", "n":len(valid),
            "first_full_window_ms":summary(valid), "runs":samples,
            "definition":"pre-launch display capture to first frame 97% matching the final window content; filesystem cache remains warm"}


def scenario(browser, name, index, record):
    browser.activate()
    actions, target, duration = [], None, 2.2
    occluder = None
    region = None
    pointer = None
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
        time.sleep(.8)
        actions = [browser.click(browser.locate("Open next local page", {"AXLink"}), at=.5)]
        target = "blue"
    elif name == "scroll":
        scroll_ident = browser.page(kind="long")
        bounds = window(browser.pid)["kCGWindowBounds"]
        act({"kind":"move","x":bounds["X"]+bounds["Width"]*.7,"y":bounds["Y"]+bounds["Height"]*.7})
        actions = scroll_actions()
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
    if name in ("navigate", "link") and browser.name == "nook":
        glyph = browser.locate("Reload", {"AXButton"})["rect"]
        attribution = {"probes":[{"name":"glyph","rect":glyph}]}
    if name == "activate":
        # The lower-right blank page contains no fixture links or browser controls.
        pointer = {"kind":"move","x":bounds["X"]+bounds["Width"]*.85,"y":bounds["Y"]+bounds["Height"]*.75}
        act(pointer); time.sleep(.3)
        x,y,w,h = window_rect
        page = [r["rect"] for r in browser.ax() if r.get("AXRole") == "AXWebArea" and browser.session in str(r.get("AXURL","")) and "rect" in r]
        if not page:
            raise Invalid("cannot identify the benchmark page rectangle")
        page = page[0]
        px,py,pw,ph = page
        attribution = {"attribute":True,"full_display":True,"window_rect":window_rect,"regions":[
            {"name":"traffic_lights","rect":[x,y,90,38]},
            {"name":"link_pill","rect":[px,y+h-44,min(500,pw),44]},
            {"name":"page","rect":page},
            {"name":"chrome_title","rect":[x,y,w,max(40,py-y)]},
            {"name":"sidebar","rect":[x,y,max(0,px-x),h]},
            {"name":"chrome_title","rect":window_rect}]}
        region = [x-20,y-20,w+40,h+40]
    if name == "activate":
        attribution["window_id"] = window(browser.pid)["kCGWindowNumber"]
        occluder = subprocess.Popen([str(HELPER), "occlude", *map(str,window_rect)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(.35)
    sampler = None
    if getattr(browser,"sample_main",False) and record:
        record.mkdir(parents=True,exist_ok=True)
        sampler = subprocess.Popen(["/usr/bin/sample",str(browser.pid),str(math.ceil(duration+1)),"1","-file",str(record/"main-thread.sample.txt")],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    start = browser.resources() if name == "scroll" else None
    t0 = time.monotonic()
    try:
        raw = capture(browser.pid, actions, duration, record, signatures=name == "activate",region=region,attribution=attribution)
    finally:
        if sampler:
            try:
                sampler.wait(timeout=20)
            except subprocess.TimeoutExpired:
                sampler.terminate(); sampler.wait(timeout=5)
        if occluder:
            occluder.terminate(); occluder.wait(timeout=5)
    if name in ("sidebar_hide", "sidebar_show"):
        sidebar_after = browser.ax()
        # Leave the fixture visible for subsequent activation and scroll scenarios.
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
    raw["load1"] = os.getloadavg()[0]
    raw["window_frame"] = bounds
    raw["pointer_park"] = pointer
    if name in ("activate", "sidebar_show", "sidebar_hide"):
        observed = raw["events"][0].get("pointer_before")
        raw["pointer_park_verified"] = bool(observed and abs(observed[0]-pointer["x"]) < 2 and abs(observed[1]-pointer["y"]) < 2)
        if not raw["pointer_park_verified"]:
            if record:
                (record/"unverified-pointer.json").write_text(json.dumps(raw)+"\n")
            raise Invalid(f"activation pointer was not parked: {observed}")
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
        raw["fixture_id"] = scroll_ident
        end = browser.resources()
        moving = [f["t"] for f in raw["frames"] if raw["events"][0]["t"] <= f["t"] <= raw["events"][0]["t"]+3 and f.get("changed",0) >= .0015]
        raw["frame_intervals"] = [{"start":a,"end":b,"ms":(b-a)*1000} for a,b in zip(moving,moving[1:])]
        metrics["cpu_percent"] = (end["cpu_s"]-start["cpu_s"])/(time.monotonic()-t0)*100
    if name == "command":
        act(text("uibench-check")); time.sleep(.1)
        focused = [r for r in browser.ax() if r.get("AXFocused") and "uibench-check" in str(r.get("AXValue", ""))]
        if not focused:
            raise Invalid("Cmd+T did not expose a focused text field accepting input")
        act(key("escape"))
        if browser.name == "chrome":
            act(key("w","cmd"))
        probes = [{"kind":"text", "text":"READY ", "at":.55+i*.05} for i in range(10)]
        ready = capture(browser.pid, [key("t","cmd"), *probes], 1.6,
                        record/"readiness" if record else None, ocr="ready")
        if ready.get("first_text_frame") is None:
            raise Invalid("no visually recognized readiness probe in captured frames")
        metrics["input_ready_ms"] = (ready["first_text_frame"]-ready["events"][0]["t"])*1000
        metrics["readiness_probe_interval_ms"] = 50
        act(key("escape"))
        if browser.name == "chrome":
            act(key("w","cmd"))
        raw["readiness"] = ready
    if name in ("keyboard", "click"):
        # The inactive blue tab is ours; select it and close it.
        row = browser.locate(destination, {"AXRadioButton", "AXTab", "AXButton"})
        if browser.name == "arc":
            browser.select_owned_tab(row)
        else:
            act(browser.click(row)); time.sleep(.15)
        browser.close_tab(); browser.owned_tabs -= 1
    if name == "close":
        browser.owned_tabs -= 1
    return {"status": "valid", **metrics, "raw": raw}


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
    video = ROOT / "build/hillclimb/bin/loop.mp4"
    if video.exists():
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
    folder.mkdir(parents=True, exist_ok=True)
    result = {}
    def close_created_window(before):
        created = [w for w in helper("windows") if w.get("kCGWindowOwnerPID") == browser.pid
                   and w.get("kCGWindowLayer") == 0 and w["kCGWindowBounds"]["Width"] > 300
                   and w["kCGWindowNumber"] not in before]
        if not created:
            return False
        target = created[0]
        bounds = target["kCGWindowBounds"]
        helper("close-window",browser.pid,*[bounds[k] for k in ("X","Y","Width","Height")])
        deadline = time.monotonic()+2
        while any(w["kCGWindowNumber"] == target["kCGWindowNumber"] for w in helper("windows")) and time.monotonic() < deadline:
            time.sleep(.1)
        if any(w["kCGWindowNumber"] == target["kCGWindowNumber"] for w in helper("windows")):
            raise Invalid("created UI window remained open after its close button was pressed")
        return True
    def shot(name, verify=None, region=None):
        if verify and not verify():
            raise Invalid(f"{name} surface did not appear")
        raw = capture(browser.pid, duration=.6, record=folder/f".{name}",native=True,region=region)
        shutil.copyfile(folder/f".{name}"/"last.png", folder/f"{name}.png")
        shutil.rmtree(folder/f".{name}")
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
        helper("press", browser.pid, ",".join(map(str,menu[0]["path"])))
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
    lines = ["| Browser | Scenario | n | First change ms med/p95 | Paint ms med/p95 | Ready/full ms med/p95 | Settle ms med/p95 | Repeats med | Worst gap ms p95 |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    def fmt(value):
        return f"{value['median']:.1f}/{value['p95']:.1f}" if value else "-"
    for browser, data in result["browsers"].items():
        if data.get("status") == "blocked":
            lines.append(f"| {browser} | blocked: {data['reason']} | 0 | - | - | - | - | - | - |")
        for name, entry in data.get("scenarios", {}).items():
            if entry.get("status") != "valid":
                lines.append(f"| {browser} | {name}: discarded | {entry.get('n',0)} | - | - | - | - | - | - |")
                continue
            s = entry["summary"]
            ready = s.get("input_ready_ms") or s.get("first_full_frame_ms")
            lines.append(f"| {browser} | {name} | {entry['n']}/{len(entry['runs'])} | {fmt(s['first_change_ms'])} | {fmt(s['first_paint_ms'])} | {fmt(ready)} | {fmt(s['settled_ms'])} | {s['dropped_frames']['median']:.0f} | {s['worst_frame_gap_ms']['p95']:.1f} |")
    lines += ["", "60 Hz visible display capture. Latencies are quantized to about 16.7 ms. "
              "Settle means the last changed frame followed by at least 250 ms of stability. "
              "Repeated frames between visible changes are a dropped-frame proxy, not GPU telemetry. "
              "Ready/full is captured typed-text echo for Cmd+T, or a 97% match to the final full window for activation. "
              "Cmd+T text probes run every 50 ms, so readiness is an upper-bound estimate. "
              "n is accepted/attempted trials. Percentiles use accepted trials. "
              "Raw samples, min/max, standard deviation, validation evidence and rejection reasons are in the JSON.", ""]
    lines += ["| Browser | Cold full window ms med/p95 | RSS MB 1/10/30 tabs | Physical MB 1/10/30 tabs | Idle CPU % | Background video CPU % | Scroll CPU % med | Scroll fps med/min |",
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
    lines += ["", "| Browser | Scenario | Visually complete ms med/p95 | Frame interval ms median/p95/max | Intervals over 20 ms med |",
              "|---|---|---:|---:|---:|"]
    for browser,data in result["browsers"].items():
        for name,entry in data.get("scenarios",{}).items():
            s = entry.get("summary",{})
            if not s: continue
            interval = "/".join(f"{s[k]['median']:.1f}" for k in ("frame_interval_median_ms","frame_interval_p95_ms","frame_interval_max_ms") if s.get(k))
            lines.append(f"| {browser} | {name} | {fmt(s.get('visually_complete_ms'))} | {interval} | {s['frame_intervals_over_20ms']['median']:.0f} |")
    return "\n".join(lines)+"\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browsers", default="nook,arc,zen,chrome")
    parser.add_argument("--only", default=",".join(SCENARIOS+["cold", "resources", "shots"]),
                        help="comma-separated keyboard,click,command,navigate,close,sidebar,activate,link,scroll,cold,resources,shots; a-i also accepted")
    parser.add_argument("--nook-app", default="build/hillclimb/base/Nook.app")
    parser.add_argument("--label", default="base")
    parser.add_argument("--record-dir", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--wait-build", type=int, default=1800)
    parser.add_argument("--signposts", type=Path, help="stream Nook.Perf events as ndjson during this invocation")
    parser.add_argument("--sample-main", action="store_true", help="collect a 1 ms process stack sample alongside each recorded trial")
    parser.add_argument("--allow-arc-quit",action="store_true",help="explicitly allow graceful Arc restarts for cold launch and resource measurements; leave it running afterward")
    args = parser.parse_args()
    if args.runs < 10:
        parser.error("at least 10 repetitions are required")
    names = args.browsers.split(",")
    if set(names)-{"nook", "arc", "zen", "chrome"}:
        parser.error("unknown browser")
    only = {ALIASES.get(n, n) for n in args.only.split(",")}
    if "sidebar" in only:
        only.remove("sidebar"); only.update(("sidebar_show","sidebar_hide"))
    if only-set(SCENARIOS+["cold", "resources", "shots"]):
        parser.error("unknown scenario")
    HELPER.parent.mkdir(parents=True, exist_ok=True)
    if not HELPER.exists() or HELPER.stat().st_mtime < SOURCE.stat().st_mtime:
        run(["swiftc", "-O", "-parse-as-library", SOURCE, "-o", HELPER], timeout=120)
    if "resources" in only and not (HELPER.parent/"loop.mp4").exists():
        helper("video", HELPER.parent/"loop.mp4")
    permissions = helper("permissions")
    result = {"label": args.label, "when": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
              "method": {"fps": 60, "sample_grid": [160,100], "change_fraction": .0015,
                         "pixel_rgb_delta": 30, "settle_guard_ms": 250,
                         "capture": "ScreenCaptureKit full-display buffer, explicit crop, cursor excluded; activation retains the full display",
                         "visually_complete": "last frame changing more than 0.5% of verified window pixels at RGB delta > 30",
                         "regions": "first matching region wins; rectangles use global top-left display coordinates; outside includes the entire captured display",
                         "frame_intervals": "time between changed presentations during the first 3 seconds of scroll input",
                         "resolution": "window in logical pixels for timings; display-native pixels for still screenshots",
                         "launcher": "LaunchServices new instance with explicit throwaway profile arguments, existing Arc reused",
                         "dropped_frames": "60 Hz repeated refresh slots between changed frames during motion",
                         "cpu": "kernel process Mach ticks converted with mach_timebase_info / wall seconds, 100% is one core",
                         "footprint": "proc_pid_rusage RUSAGE_INFO_V4, descendants plus responsible PID helpers",
                         "input_ready": "first captured echo of repeated text probes, recognized offline with Vision; 50 ms probe interval"},
              "permissions": permissions, "load1": os.getloadavg()[0], "browsers": {}}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    blockers = []
    def save():
        args.out.write_text(json.dumps(result, indent=2)+"\n")
        args.out.with_suffix(".md").write_text(markdown(result))
        (args.out.parent/"BLOCKERS.md").write_text("# UI benchmark blockers and discarded measurements\n\n"+"\n".join(f"- {b}" for b in blockers)+"\n")
    if not all(permissions.values()):
        reason = "macOS desktop is locked" if permissions.get("unlocked") is False else f"macOS permission missing: {permissions}"
        result["browsers"] = {name:{"status":"blocked","reason":reason} for name in names}
        blockers.append(reason); save(); return 1
    server = bench.DualStackServer(("::", bench.PORT), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    paths = {"nook": args.nook_app, "arc": "/Applications/Arc.app", "zen": "/Applications/Zen.app", "chrome": "/Applications/Google Chrome.app"}
    trace = None
    trace_file = None
    if args.signposts:
        args.signposts.parent.mkdir(parents=True,exist_ok=True)
        trace_file = args.signposts.open("w")
        trace = subprocess.Popen(["/usr/bin/log","stream","--signpost","--level","debug","--style","ndjson","--predicate",'subsystem == "Nook.Perf"'],stdout=trace_file,stderr=subprocess.STDOUT)
        time.sleep(.5)
        if trace.poll() is not None:
            trace_file.close()
            raise Invalid("signpost stream exited before launch")
    result["desktop_settings"] = {f"{domain}.{key}":subprocess.run(["defaults","read",domain,key],capture_output=True,text=True).stdout.strip()
                                  for domain,key in (("com.apple.WindowManager","GloballyEnabled"),
                                                     ("NSGlobalDomain","NSAutomaticWindowAnimationsEnabled"),
                                                     ("com.apple.universalaccess","reduceMotion"),
                                                     ("com.apple.universalaccess","reduceTransparency"))}
    result["os_version"] = run(["sw_vers"]).strip()
    calibrated = False
    try:
        for name in names:
            data = result["browsers"][name] = {"scenarios": {}}
            browser = None
            try:
                if name == "nook":
                    deadline = time.monotonic()+args.wait_build
                    exe = Path(args.nook_app)/"Contents/MacOS/Nook"
                    while not exe.exists() and time.monotonic() < deadline:
                        log("waiting for baseline Nook build"); time.sleep(5)
                    if not exe.exists():
                        raise Invalid("baseline build did not appear before wait deadline")
                browser = Browser(name, paths[name])
                browser.sample_main = args.sample_main
                if "cold" in only:
                    log(f"{name}: {args.runs} cold launches with pre-launch capture")
                    try:
                        data["cold_launch"] = cold_launch(name, paths[name], args.runs, args.record_dir/name/"cold" if args.record_dir else None,args.allow_arc_quit)
                    finally:
                        if name == "arc" and args.allow_arc_quit:
                            data["left_running_pid"] = leave_arc_running(paths[name])
                    if data["cold_launch"]["status"] != "valid":
                        blockers.append(f"{name} cold: {data['cold_launch'].get('reason', 'fewer than ten validated cold trials')}")
                    save()
                log(f"{name}: launching isolated benchmark session")
                browser.launch()
                data["launch_overrides"] = {"hideWebContentBorder":os.environ.get("M3_HIDE_BORDER","NO"),"showLinkStatusBar":os.environ.get("M3_LINK_STATUS","YES")} if name == "nook" else {}
                data.update({"version": browser.version, "pid": browser.pid, "profile": "existing Arc, benchmark tabs only" if name == "arc" else "throwaway"})
                if not calibrated:
                    data["validation"] = validation(browser, args.record_dir/name/"calibration" if args.record_dir else None)
                    calibrated = True
                    log(f"{name}: synthetic capture calibration passed")
                browser.page(new=name != "zen")
                for scenario_name in SCENARIOS:
                    if scenario_name not in only:
                        continue
                    entry = data["scenarios"][scenario_name] = {"runs": []}
                    log(f"{name}: {scenario_name}, {args.runs} repetitions")
                    for i in range(args.runs*2):
                        try:
                            rec = args.record_dir/name/scenario_name/f"{i+1:02d}" if args.record_dir else None
                            entry["runs"].append(scenario(browser, scenario_name, i, rec))
                        except (Invalid, subprocess.TimeoutExpired) as error:
                            entry["runs"].append({"status":"discarded", "reason":str(error)})
                            # An unsupported control cannot yield ten validated trials.
                            if i == 0 and any(reason in str(error) for reason in ("no comparable", "no visible accessible control", "foreground application")):
                                break
                        if sum(r["status"] == "valid" for r in entry["runs"]) >= args.runs:
                            break
                    valid = [r for r in entry["runs"] if r["status"] == "valid"]
                    entry["n"] = len(valid)
                    entry["status"] = "valid" if len(valid) >= 10 else "discarded"
                    if entry["status"] == "valid":
                        entry["summary"] = {field:summary([r.get(field) for r in valid]) for field in valid[0] if field not in ("raw","status")}
                    else:
                        reasons = sorted({r["reason"] for r in entry["runs"] if "reason" in r})
                        entry["reason"] = "; ".join(reasons) or "fewer than ten validated repetitions"
                        blockers.append(f"{name} {scenario_name}: {entry['reason']}")
                    save()
                if "shots" in only:
                    if name != "arc":
                        browser.cleanup(); browser = Browser(name, paths[name]); browser.launch()
                    try:
                        data["shots"] = screenshots(browser, args.out.parent/"shots"/name)
                    except (Invalid, subprocess.TimeoutExpired) as error:
                        data["shots_error"] = str(error); blockers.append(f"{name} screenshots: {error}")
                        if window(browser.pid):
                            try:
                                capture(browser.pid,duration=.6,record=args.out.parent/"shots"/name/"blocked-shots")
                            except (Invalid,subprocess.TimeoutExpired):
                                pass
                if "resources" in only:
                    # Relaunch so UI trials and screenshots cannot contaminate tab count.
                    if name != "arc":
                        browser.cleanup(); browser = Browser(name, paths[name]); browser.launch()
                    elif args.allow_arc_quit:
                        browser.cleanup()
                        quit_arc(paths[name]); leave_arc_running(paths[name])
                        browser = Browser(name, paths[name]); browser.launch()
                    try:
                        data["resources"] = resource_scenarios(browser,args.allow_arc_quit)
                    except (Invalid, subprocess.TimeoutExpired) as error:
                        data["resources"] = {"status":"discarded", "reason":str(error)}
                        blockers.append(f"{name} resources: {error}")
            except (Invalid, OSError, subprocess.TimeoutExpired) as error:
                data.update({"status":"blocked", "reason":str(error)})
                blockers.append(f"{name}: {error}"); log(f"{name}: blocked: {error}")
                if browser and browser.pid and window(browser.pid):
                    try:
                        capture(browser.pid, duration=.6, record=args.out.parent/"shots"/name/"blocked")
                    except (Invalid, subprocess.TimeoutExpired):
                        pass
            finally:
                if browser:
                    browser.cleanup()
                    if getattr(browser,"cleanup_error",None):
                        data["cleanup_error"] = browser.cleanup_error
                        blockers.append(f"{name} cleanup: {browser.cleanup_error}")
                if name == "arc" and args.allow_arc_quit:
                    data["left_running_pid"] = leave_arc_running(paths[name])
                save()
    finally:
        if trace:
            trace.terminate(); trace.wait(timeout=5); trace_file.close()
        args.out.with_name(args.out.stem+"-beacons.json").write_text(json.dumps(list(Handler.events.values()),indent=2)+"\n")
        server.shutdown()
        bench.forget_favicons([bench.PORT])
    print(markdown(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
