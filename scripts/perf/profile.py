#!/usr/bin/env python3
"""Sample the app while it opens tabs. Usage: profile.py APP OUT.txt [kind] [count]"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

import bench
import experiment


def profile(args):
    app = bench.App(args.app)
    server = bench.DualStackServer(("::", bench.PORT), bench.Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    ports = []
    sampler = None
    with tempfile.TemporaryDirectory(prefix="nookperf-") as state:
        try:
            ports = bench.start_new_sites()
            bench.SERVE_FAVICON[0] = not args.no_favicon
            experiment.check_load()
            app.defaults()
            app.launch(state)
            time.sleep(3)
            app.open(f"{bench.HOST}/p/light?id=warm")
            bench.wait_beacons(["warm"], 20)
            time.sleep(1)
            sampler = subprocess.Popen(
                ["sample", str(app.proc.pid), "8", "1", "-file", str(args.out)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            time.sleep(.5)
            before = app.cpu()
            for index in range(args.count):
                app.open(f"{bench.host(f'p{index}')}/p/{args.kind}?id=p{index}")
                time.sleep(.6)
            sampler.wait()
            print("cpu", round(app.cpu() - before, 2))
        finally:
            with experiment.finish_on_interrupt():
                try:
                    if sampler and sampler.poll() is None:
                        sampler.terminate()
                        sampler.wait(timeout=5)
                finally:
                    try:
                        app.quit(graceful=False)
                    finally:
                        server.shutdown()
                        server.server_close()
                        bench.forget_favicons(ports + [bench.PORT])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app")
    parser.add_argument("out", type=Path)
    parser.add_argument("kind", nargs="?", default="dom")
    parser.add_argument("count", nargs="?", type=int, default=10)
    parser.add_argument("--no-favicon", action="store_true")
    args = parser.parse_args()
    paths = (tempfile.gettempdir(), args.out)
    experiment.disk_headroom(paths, experiment.CAPTURE_FREE_GIB)
    with experiment.cooperative_signals(), experiment.exclusive():
        experiment.disk_headroom(paths, experiment.CAPTURE_FREE_GIB)
        experiment.check_evidence([args.out])
        profile(args)


if __name__ == "__main__":
    try:
        main()
    except experiment.Interrupted as error:
        print(error, file=sys.stderr)
        sys.exit(128 + error.signum)
    except experiment.Invalid as error:
        sys.exit(str(error))
