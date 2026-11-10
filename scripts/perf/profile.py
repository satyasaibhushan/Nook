#!/usr/bin/env python3
"""Samples the app while it opens tabs. usage: profile.py APP OUT.txt [kind] [count]"""
import subprocess, sys, tempfile, threading, time
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import bench
from http.server import ThreadingHTTPServer
app_path, out = sys.argv[1], sys.argv[2]
kind = sys.argv[3] if len(sys.argv) > 3 else "dom"
count = int(sys.argv[4]) if len(sys.argv) > 4 else 10
server = bench.DualStackServer(("::", bench.PORT), bench.Handler); server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
ports = bench.start_new_sites()
bench.SERVE_FAVICON[0] = "--no-favicon" not in sys.argv
app = bench.App(app_path); app.defaults()
state = tempfile.mkdtemp(prefix="nookperf-")
app.launch(state); time.sleep(3)
app.open(f"{bench.HOST}/p/light?id=warm"); bench.wait_beacons(["warm"], 20); time.sleep(1)
sampler = subprocess.Popen(["sample", str(app.proc.pid), "8", "1", "-file", out], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.5)
c0 = app.cpu()
for i in range(count):
    app.open(f"{bench.host(f'p{i}')}/p/{kind}?id=p{i}"); time.sleep(0.6)
sampler.wait()
print("cpu", round(app.cpu() - c0, 2))
app.quit(graceful=False)
bench.forget_favicons(ports + [bench.PORT])
