#!/usr/bin/env python3
"""Black-box browsing benchmark for a Nook build.

Serves synthetic pages from 127.0.0.1, opens them in the app through nook://open, and lets
each page report its own timings back. Every run uses a throwaway tab state directory and the
build's own bundle id, so an installed Nook is never touched.

  scripts/perf/bench.py --app build/Build/Products/Release/Nook.app --label base --out out.json
"""
import argparse, json, os, plistlib, shutil, socket, statistics, subprocess, sys, tempfile, threading, time
import struct, urllib.parse, urllib.request, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8765
MCP_PORT = 47901
HOST = f"http://127.0.0.1:{PORT}"

first_request = {}   # id -> wall time of the first document request
beacons = {}         # id -> payload
doc_requests = {}    # id -> how many times the document itself was requested
lock = threading.Lock()
arrived = threading.Condition(lock)

BEACON = """
<script>
(function(){
  var id = new URLSearchParams(location.search).get('id');
  function send(extra){
    var nav = performance.getEntriesByType('navigation')[0] || {};
    var fcp = performance.getEntriesByName('first-contentful-paint')[0];
    var body = Object.assign({id:id, timeOrigin:performance.timeOrigin, fcp:fcp?fcp.startTime:null,
      dcl:nav.domContentLoadedEventEnd, load:nav.loadEventEnd, resp:nav.responseStart,
      hidden:document.hidden}, extra||{});
    navigator.sendBeacon('/beacon', JSON.stringify(body));
  }
  window.addEventListener('load', function(){
    setTimeout(function(){
      if (!window.__after) return send();
      window.__after().then(send);
    }, 250);
  });
})();
</script>
"""

def png(size=32, rgb=(40, 120, 220)):
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
FAVICON = png()
favicon_hits = [0]

def host(n=None):
    """The known host, or a host the app has never seen (any name under localhost is loopback)."""
    return HOST if n is None else f"http://{n}.localhost:{PORT}"

def words(n, seed=0):
    base = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt".split()
    return " ".join(base[(i * 7 + seed) % len(base)] for i in range(n))

def page(kind, pid):
    head = f"<!doctype html><html><head><meta charset=utf-8><title>{kind} {pid}</title>"
    if kind == "light":
        return head + f"</head><body><h1>Light</h1><p>{words(200)}</p>{BEACON}</body></html>"
    if kind == "dom":
        css = "".join(f".c{i}{{padding:{i%7}px;margin:{i%5}px;border:1px solid #{i%10}{i%10}{i%10}}}" for i in range(400))
        rows = "".join(
            f"<div class='card c{i%400}'><h3>Item {i}</h3><p>{words(18, i)}</p>"
            f"<a href='/p/light?id=x{i}'>link {i}</a><span class='c{(i*3)%400}'>{i}</span></div>"
            for i in range(5000))
        return head + f"<style>{css}.card{{display:inline-block;width:220px}}</style></head><body>{rows}{BEACON}</body></html>"
    if kind == "js":
        tags = "".join(f"<script src='/asset/s{i}.js?id={pid}'></script>" for i in range(30))
        inline = "<script>var t=0;for(var i=0;i<6e6;i++){t+=Math.sqrt(i)%3}document.title='js '+t</script>"
        return head + f"</head><body><h1>Scripts</h1>{tags}{inline}<p>{words(100)}</p>{BEACON}</body></html>"
    if kind == "res":
        imgs = "".join(f"<img src='/asset/i{i}.svg?id={pid}' width=40 height=40>" for i in range(120))
        css = "".join(f"<link rel=stylesheet href='/asset/c{i}.css?id={pid}'>" for i in range(15))
        js = "".join(f"<script src='/asset/s{i}.js?id={pid}' defer></script>" for i in range(15))
        return head + css + f"</head><body><h1>Resources</h1>{imgs}{js}{BEACON}</body></html>"
    if kind == "dyn":
        # Mutation-heavy app-like page with frames: stresses whatever the browser injects.
        frames = "".join(f"<iframe src='/p/frame?id={pid}f{i}' width=300 height=120></iframe>" for i in range(4))
        script = """
<script>
window.__after = function(){
  return new Promise(function(done){
    var root = document.getElementById('root'), n = 0, t0 = performance.now();
    function step(){
      for (var i = 0; i < 60; i++) {
        var d = document.createElement('div');
        d.className = 'row'; d.textContent = 'row ' + n + ' ' + Math.random();
        d.setAttribute('data-i', n); root.appendChild(d);
        if (n % 3 == 0 && root.firstChild) root.removeChild(root.firstChild);
        n++;
      }
      history.replaceState(null, '', location.pathname + location.search + '#' + n);
      if (n < 6000) { ch.port2.postMessage(0); }
      else done({mut: performance.now() - t0});
    }
    var ch = new MessageChannel(); ch.port1.onmessage = step;
    ch.port2.postMessage(0);
  });
};
</script>"""
        return head + f"</head><body><h1>Dynamic</h1>{frames}<div id=root></div><p>{words(300)}</p>{script}{BEACON}</body></html>"
    if kind == "frame":
        return head + f"</head><body><p>{words(40)}</p><script>setInterval(function(){{document.body.appendChild(document.createElement('i'))}},50)</script></body></html>"
    return None

def asset(name):
    if name.endswith(".js"):
        i = int(name[1:-3])
        body = f"(function(){{var a=[];for(var i=0;i<20000;i++)a.push(i*{i+1}%97);window.__s{i}=a.length;}})();\n" + ("// " + words(60) + "\n") * 150
        return "application/javascript", body
    if name.endswith(".css"):
        i = int(name[1:-4])
        return "text/css", "".join(f".r{i}_{j}{{color:#{j%10}{i%10}{j%10};padding:{j%9}px}}" for j in range(300))
    if name.endswith(".svg"):
        i = int(name[1:-4])
        return "image/svg+xml", f"<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><rect width='40' height='40' fill='hsl({i*3},70%,50%)'/><text x='4' y='24' font-size='12'>{i}</text></svg>"
    return None, None

class DualStackServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def reply(self, ctype, body, code=200):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        now = time.time()
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        parts = url.path.strip("/").split("/")
        if parts[0] == "p" and len(parts) == 2:
            pid = q.get("id", ["?"])[0]
            with lock:
                first_request.setdefault(pid, now)
                doc_requests[pid] = doc_requests.get(pid, 0) + 1
            body = page(parts[1], pid)
            return self.reply("text/html; charset=utf-8", body) if body else self.reply("text/plain", "no", 404)
        if parts[0] == "asset" and len(parts) == 2:
            ctype, body = asset(parts[1])
            return self.reply(ctype, body) if body else self.reply("text/plain", "no", 404)
        if url.path == "/favicon.ico":
            favicon_hits[0] += 1
            return self.reply("image/png", FAVICON)
        self.reply("text/plain", "no", 404)
    def do_POST(self):
        now = time.time()
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        try:
            b = json.loads(data); b["received"] = now
            with arrived:
                beacons[b["id"]] = b
                arrived.notify_all()
        except Exception: pass
        self.reply("text/plain", "ok")

def wait_beacons(ids, timeout):
    deadline = time.time() + timeout
    with arrived:
        while not all(i in beacons for i in ids):
            left = deadline - time.time()
            if left <= 0: return False
            arrived.wait(left)
    return True

# --- app control ---------------------------------------------------------------------------

class App:
    def __init__(self, path):
        self.path = os.path.abspath(path)
        with open(os.path.join(self.path, "Contents/Info.plist"), "rb") as f:
            self.bundle = plistlib.load(f)["CFBundleIdentifier"]
        assert self.bundle != "com.gstudios.nook", "refusing to drive the installed app's bundle id"
        self.exe = os.path.join(self.path, "Contents/MacOS/Nook")
        self.proc = None
        self.token = None

    def defaults(self):
        for key, val in [("settings.didFinishOnboarding", True), ("settings.allowNookURLs", True),
                         ("settings.developerMode", True), ("settings.browserControlServer", True),
                         ("settings.askBeforeQuit", False), ("settings.warnBeforeHTTP", False),
                         ("settings.externalLinksInMiniWindow", False)]:
            subprocess.run(["defaults", "write", self.bundle, key, "-bool", "true" if val else "false"], check=True)
        subprocess.run(["defaults", "write", self.bundle, "NSQuitAlwaysKeepsWindows", "-bool", "false"], check=True)

    def launch(self, state_dir, url=None):
        args = [self.exe, "-NookStateDir", state_dir, "-NookDevMCPPort", str(MCP_PORT),
                "-ApplePersistenceIgnoreState", "YES"]
        t0 = time.time()
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ready = None
        while time.time() - t0 < 30:
            try:
                socket.create_connection(("127.0.0.1", MCP_PORT), timeout=0.05).close()
                ready = time.time(); break
            except OSError:
                time.sleep(0.005)
        tok = os.path.expanduser(f"~/Library/Application Support/{self.bundle}/dev-mcp-token")
        for _ in range(100):
            if os.path.exists(tok): break
            time.sleep(0.05)
        self.token = open(tok).read().strip() if os.path.exists(tok) else None
        return t0, ready

    def open(self, url, background=False):
        link = "nook://open?url=" + urllib.parse.quote(url, safe="") + ("&background=1" if background else "")
        t0 = time.time()
        subprocess.run(["open", "-a", self.path, link], check=False)
        return t0

    def mcp(self, tool, args=None):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                           "params": {"name": tool, "arguments": args or {}}}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{MCP_PORT}/mcp", data=body, headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=40) as r:
            res = json.loads(r.read())
        return res.get("result", {}).get("content", [{}])[0].get("text", "")

    def cpu(self):
        """CPU seconds the app process itself has used."""
        out = subprocess.run(["ps", "-o", "time=", "-p", str(self.proc.pid)], capture_output=True, text=True).stdout.strip()
        if not out: return None
        m, s = out.split(":")[-2:]
        return int(m) * 60 + float(s)

    def web_pids(self):
        try:
            txt = self.mcp("pages")
            start = txt.index("["); end = txt.rindex("]") + 1
            return sorted({p["pid"] for p in json.loads(txt[start:end]) if p.get("pid", 0) > 0}), txt
        except Exception as e:
            return [], str(e)

    def memory(self):
        """Physical footprint in MB: the app, and the WebContent processes of its live pages."""
        def fp(pid):
            out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
            for line in out.splitlines():
                if "Footprint:" in line or "phys_footprint:" in line:
                    num, unit = line.split(":")[-1].split()[:2]
                    return float(num) * {"KB": 1/1024, "MB": 1, "GB": 1024}.get(unit, 1)
            return 0.0
        pids, _ = self.web_pids()
        return {"app_mb": round(fp(self.proc.pid), 1), "web_mb": round(sum(fp(p) for p in pids), 1), "web_procs": len(pids)}

    def quit(self, graceful=True):
        if not self.proc: return
        if graceful:
            subprocess.run(["osascript", "-e", f'tell application id "{self.bundle}" to quit'],
                           capture_output=True, timeout=15)
            try: self.proc.wait(10)
            except subprocess.TimeoutExpired: pass
        if self.proc.poll() is None:
            self.proc.terminate()
            try: self.proc.wait(5)
            except subprocess.TimeoutExpired: self.proc.kill()
        self.proc = None
        time.sleep(1.0)

def med(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs), 1) if xs else None

def timing(pid, t0):
    b = beacons[pid]; origin = b["timeOrigin"] / 1000
    ms = lambda v: None if v is None else round((origin + v / 1000 - t0) * 1000, 1)
    return {"request": round((first_request[pid] - t0) * 1000, 1), "fcp": ms(b.get("fcp")),
            "dcl": ms(b.get("dcl")), "load": ms(b.get("load")),
            "page_fcp": b.get("fcp"), "page_load": b.get("load"),
            "mut": b.get("mut"), "hidden": b.get("hidden")}

# --- scenarios -----------------------------------------------------------------------------

def scenario_cold(app, runs):
    out = []
    for r in range(runs):
        state = tempfile.mkdtemp(prefix="nookperf-")
        pid = f"cold{r}-{int(time.time())}"
        t0, ready = app.launch(state)
        app.open(f"{HOST}/p/light?id={pid}")
        ok = wait_beacons([pid], 30)
        row = {"ready": round((ready - t0) * 1000, 1) if ready else None}
        if ok: row.update({"first_load": timing(pid, t0)["load"]})
        time.sleep(1.5)
        row["cpu_s"] = app.cpu()
        out.append(row)
        app.quit(graceful=False)
        shutil.rmtree(state, ignore_errors=True)
    rows = out[1:] if len(out) > 1 else out   # the first launch pays the disk cache
    return {"ready_ms": med([r["ready"] for r in rows]), "first_load_ms": med([r.get("first_load") for r in rows]),
            "launch_cpu_s": med([r["cpu_s"] for r in rows]), "runs": out}

def scenario_single(app, runs, kinds, new_hosts=False):
    state = tempfile.mkdtemp(prefix="nookperf-")
    app.launch(state)
    time.sleep(3)
    warm = "warm" + str(int(time.time()))
    app.open(f"{HOST}/p/light?id={warm}"); wait_beacons([warm], 20)
    assert warm in app.web_pids()[1], "the link opened in another copy of the app"
    res = {}
    cpu0 = app.cpu()
    for kind in kinds:
        rows = []
        for r in range(runs):
            pid = f"{kind}{r}-{int(time.time()*1000)}"
            base = host(f"s{pid}") if new_hosts else host()
            t0 = app.open(f"{base}/p/{kind}?id={pid}")
            if wait_beacons([pid], 30): rows.append(timing(pid, t0))
            time.sleep(0.4)
        res[kind] = {k: med([row[k] for row in rows]) for k in ["request", "fcp", "dcl", "load", "page_fcp", "page_load", "mut"]}
        res[kind]["n"] = len(rows)
        res[kind]["load_all"] = [row["load"] for row in rows]
    time.sleep(2)   # let any trailing per-load work finish so it is counted
    res["app_cpu_s"] = round(app.cpu() - cpu0, 2)
    mine = [n for i, n in list(doc_requests.items()) if i.rstrip("0123456789-") in kinds]
    res["doc_requests_per_load"] = round(sum(mine) / max(1, len(mine)), 2)
    doc_requests.clear()
    app.quit(graceful=False)
    shutil.rmtree(state, ignore_errors=True)
    return res

def scenario_burst(app, count, kinds):
    state = tempfile.mkdtemp(prefix="nookperf-")
    app.launch(state)
    time.sleep(3)
    warm = "warm" + str(int(time.time()))
    app.open(f"{HOST}/p/light?id={warm}"); wait_beacons([warm], 20)
    assert warm in app.web_pids()[1], "the link opened in another copy of the app"
    time.sleep(1)
    cpu0 = app.cpu()
    stamp = int(time.time())
    ids = [f"b{i}-{stamp}" for i in range(count)]
    t0 = time.time()
    for i, pid in enumerate(ids):
        app.open(f"{host(pid) if i % 2 else host()}/p/{kinds[i % len(kinds)]}?id={pid}")
    opened = time.time()
    ok = wait_beacons(ids, 90)
    done = time.time()
    time.sleep(2)
    cpu1 = app.cpu()
    loaded = sum(1 for i in ids if i in beacons)
    time.sleep(4)
    mem = app.memory()
    c0 = app.cpu(); time.sleep(10); idle = app.cpu() - c0
    # Switch back through tabs is not scriptable without ids; the restore scenario covers reuse.
    res = {"tabs": count, "loaded": loaded, "all_loaded_ms": round((done - t0) * 1000) if ok else None,
           "open_calls_ms": round((opened - t0) * 1000), "app_cpu_s": round(cpu1 - cpu0, 2),
           "idle_cpu_10s": round(idle, 2), **mem}
    app.quit(graceful=True)
    # Relaunch on the same state: session restore with `count` saved tabs.
    t0, ready = app.launch(state)
    time.sleep(8)
    rmem = app.memory()
    res["restore"] = {"ready_ms": round((ready - t0) * 1000, 1) if ready else None,
                      "cpu_8s": app.cpu(), **rmem}
    app.quit(graceful=False)
    shutil.rmtree(state, ignore_errors=True)
    return res

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--label", default="run")
    ap.add_argument("--out")
    ap.add_argument("--runs", type=int, default=6)
    ap.add_argument("--burst", type=int, default=30)
    ap.add_argument("--only", default="cold,single,newhost,burst")
    a = ap.parse_args()

    server = DualStackServer(("::", PORT), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()

    app = App(a.app)
    app.defaults()
    kinds = ["light", "dom", "js", "res", "dyn"]
    result = {"label": a.label, "app": app.path, "when": time.strftime("%H:%M:%S"),
              "load1": os.getloadavg()[0]}
    try:
        if "cold" in a.only: result["cold"] = scenario_cold(app, 5)
        if "single" in a.only: result["single"] = scenario_single(app, a.runs, kinds)
        if "newhost" in a.only: result["newhost"] = scenario_single(app, a.runs, kinds, new_hosts=True)
        if "burst" in a.only: result["burst"] = scenario_burst(app, a.burst, kinds)
    finally:
        app.quit(graceful=False)
    text = json.dumps(result, indent=1)
    if a.out:
        with open(a.out, "w") as f: f.write(text)
    print(text)

if __name__ == "__main__":
    main()
