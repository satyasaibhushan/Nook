#!/usr/bin/env python3
"""One bounded interleaved round. Invoke under the shared build lock."""
import argparse
import base64
import colorsys
import functools
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import threading
import time

import uibench as u

H = Path('/Users/satyasaibhushan/Code/Personal/Nook/build/hillclimb')
OUT = H / 'measure-3'
CONDITIONS = ['current', 'border', 'status', 'plain', 'chrome']
PALETTE = [tuple(round(c * 255) for c in colorsys.hls_to_rgb((i*31 % 360)/360, .4, .65)) for i in range(100)]


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def actions():
    return u.scroll_actions()


@functools.lru_cache(maxsize=4096)
def color_label(color):
    distances = [sum(abs(a-b) for a,b in zip(color, p)) for p in PALETTE]
    n = min(range(len(distances)), key=distances.__getitem__)
    return n if distances[n] <= 8 else None


def decode(rgb, section_top, scan_y, height=120):
    """Use the fixture's existing static row backgrounds as a presentation ruler."""
    colors = [tuple(rgb[i:i+3]) for i in range(0, len(rgb), 3)]
    labels = [color_label(color) for color in colors]
    runs = []
    start = 0
    for y in range(1,len(labels)+1):
        if y == len(labels) or labels[y] != labels[start]:
            if labels[start] is not None and y-start >= 8:
                runs.append((labels[start],start,y))
            start = y
    boundaries = []
    for a,b in zip(runs,runs[1:]):
        if b[0] == a[0]+1 and b[1]-a[2] <= 6:
            y = (a[2]+b[1])/2
            boundaries.append(section_top+b[0]*height-(scan_y+y))
    if not boundaries or max(boundaries)-min(boundaries) > 2:
        raise u.Invalid(f'presented offset could not be decoded consistently: {boundaries}')
    return statistics.median(boundaries)


def metrics(raw, beacon):
    t0 = raw['events'][0]['t']
    points = []
    previous = None
    for frame in raw['frames']:
        if 'scroll_scan_rgb' in frame:
            previous = decode(base64.b64decode(frame['scroll_scan_rgb']), beacon['sectionTop'], raw['scan_page_y'], beacon['sectionHeight'])
        if previous is not None:
            points.append({'t':frame['t'], 'y':previous, 'idle':frame.get('idle', False)})
    before = [p for p in points if p['t'] < t0]
    if not before or max(p['y'] for p in before)-min(p['y'] for p in before) > 1:
        raise u.Invalid('missing stable pre-input presentation')
    # The page origin need not be exposed through accessibility. Its constant
    # screen translation cancels against the stationary pre-input ruler.
    baseline = before[-1]['y']
    for p in points:
        p['y'] -= baseline
    moving = []
    prev = before[-1]
    for p in points:
        if not t0 <= p['t'] <= t0+3:
            continue
        if abs(p['y']-prev['y']) >= 1:
            moving.append({**p, 'jump':p['y']-prev['y']})
        prev = p
    if len(moving) < 60:
        raise u.Invalid('insufficient presented scrolling')
    gaps = [(b['t']-a['t'])*1000 for a,b in zip(moving,moving[1:])]
    clock = raw['clock']
    page = [{'t':(beacon['origin']+t)/1000+clock['host_seconds']-clock['wall_seconds'], 'y':y, 'page_ms':t} for t,y in beacon['frames']]
    page = [p for p in page if t0 <= p['t'] <= t0+3]
    raf_gaps = [b['page_ms']-a['page_ms'] for a,b in zip(page,page[1:])]
    wheel = beacon['wheel']
    if beacon['viewport'] != [930,750]:
        raise u.Invalid(f'content viewport mismatch: {beacon["viewport"]}')
    if not wheel or any(mode != 0 or delta < 0 or abs(delta/12-round(delta/12)) > .01 for _,delta,mode in wheel) or abs(sum(e[1] for e in wheel)-4320) > 1:
        raise u.Invalid('page did not receive the complete pixel-precise scroll gesture')
    if abs(points[-1]['y']-4320) > 2 or abs(beacon['frames'][-1][1]-4320) > 2:
        raise u.Invalid(f'incomplete gesture: presented {points[-1]["y"]}, page {beacon["frames"][-1][1]}')
    return {'fps':len(moving)/3, 'presented_gaps_over_20ms':sum(g>20 for g in gaps),
            'largest_jump_px':max(p['jump'] for p in moving), 'first_movement_px':moving[0]['jump'],
            'first_movement_ms':(moving[0]['t']-t0)*1000, 'worst_presented_gap_ms':max(gaps),
            'raf_gaps_over_20ms':sum(g>20 for g in raf_gaps), 'raf_fps':len(page)/3,
            'worst_raf_gap_ms':max(raf_gaps), 'wheel_events':len(wheel),
            'posted_interval_max_ms':max((b['t']-a['t'])*1000 for a,b in zip(raw['events'][1:-1],raw['events'][2:-1])),
            'presented':points, 'movement':moving, 'raf':page}


class Plain(u.Browser):
    def launch(self, **kw):
        self.ident = self.session+'-plain'
        url, _ = self.url(kind='long', ident=self.ident)
        launched = u.spec_call('launch', {'app':str(self.path), 'args':[str(self.exe), url]})
        self.pid = launched['pid']
        self.proc = u.OwnedProcess(self.pid)
        u.KEYBOARD_OWNER = self.pid
        time.sleep(2)
        self.activate()
        u.helper('resize', self.pid)
        time.sleep(1)

    def page(self, **kw):
        # The first document can load before AX window normalization finishes.
        u.Handler.events.pop((self.ident,'load'),None)
        u.KEYS['r'] = 15
        u.act(u.key('r','cmd'))
        deadline = time.monotonic()+5
        while (self.ident,'load') not in u.Handler.events and time.monotonic() < deadline:
            time.sleep(.05)
        if (self.ident,'load') not in u.Handler.events:
            raise u.Invalid('plain fixture reload beacon missing')
        time.sleep(.35)
        return self.ident


def checked_wait(seconds):
    if time.monotonic()+seconds > DEADLINE:
        raise TimeoutError('bounded round deadline; resume in another invocation')
    time.sleep(seconds)


def unlocked():
    ledger = OUT/'scroll-lock-retries.json'
    for _ in range(11):
        permissions = u.helper('permissions')
        if permissions['unlocked']:
            if not all(permissions.values()):
                raise RuntimeError(f'permission missing: {permissions}')
            return
        count = json.loads(ledger.read_text()) if ledger.exists() else 0
        if count >= 10:
            raise RuntimeError('screen locked after ten 60-second retries')
        checked_wait(60)
        save(ledger, count+1)


def retry(fn, *a, **kw):
    for attempt in range(4):
        unlocked()
        try:
            return fn(*a, **kw)
        except u.ForeignWindow as error:
            with (OUT/'scroll-obstructions.txt').open('a') as f:
                f.write(json.dumps({'round':ROUND, 'attempt':attempt+1, 'reason':str(error), 'load1':os.getloadavg()[0]})+'\n')
            if attempt == 3:
                raise RuntimeError('display obstructed after three 30-second retries') from error
            print('Foreign window detected; waiting 30 seconds', flush=True)
            checked_wait(30)


def cleanup(browser, record):
    if browser.proc:
        ids = browser.pids() if browser.proc.poll() is None else []
        assert not {53709, 10634}.intersection(ids)
        owned = [u.OwnedProcess(pid) for pid in ids]
        record['owned_processes'] = [{'pid':p.pid, 'identity':p.identity} for p in owned]
        browser.proc.terminate()
        try:
            browser.proc.wait(8)
        except subprocess.TimeoutExpired:
            browser.proc.kill()
            browser.proc.wait(3)
        for proc in owned:
            proc.terminate()
        for proc in owned:
            try:
                proc.wait(3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(3)
        record['remaining'] = [p.pid for p in owned if p.poll() is None]
    browser.temp.cleanup()
    browser.closed = True


def trial(condition, attempt):
    unlocked()
    u.KEYBOARD_OWNER = None
    os.environ['M3_HIDE_BORDER'] = 'YES' if condition == 'border' else 'NO'
    os.environ['M3_LINK_STATUS'] = 'NO' if condition == 'status' else 'YES'
    os.environ['M3_SMALL_CACHE'] = '1'
    if condition == 'plain':
        b = Plain('plain', OUT/'Plain.app')
    elif condition == 'chrome':
        b = u.Browser('chrome', '/Applications/Google Chrome.app')
    else:
        b = u.Browser('nook', H/'variants/m3/Nook.app')
    stem = f'scroll-r{ROUND:02d}-{condition}-a{attempt}'
    record = {'round':ROUND, 'condition':condition, 'attempt':attempt, 'status':'discarded'}
    raw = beacon = None
    try:
        retry(b.launch)
        record.update({'pid':b.pid, 'identity':b.proc.identity, 'profile':b.temp.name,
                       'launch_command':u.run(['ps','-p',b.pid,'-o','command=']).strip()})
        with (OUT/'scroll-launched.txt').open('a') as f:
            f.write(json.dumps(record)+'\n')
        if condition == 'current' and not (OUT/'scroll-calibration.json').exists():
            save(OUT/'scroll-calibration.json', retry(u.validation, b, OUT/'scroll-calibration-rec'))
        ident = retry(b.page, kind='long')
        bounds = u.window(b.pid)['kCGWindowBounds']
        viewport = u.Handler.events[(ident,'load')]['viewport']
        u.helper('resize',b.pid,bounds['X'],bounds['Y'],bounds['Width']+930-viewport[0],bounds['Height']+750-viewport[1])
        time.sleep(.5)
        bounds = u.window(b.pid)['kCGWindowBounds']
        scan_y = bounds['Y']+240
        scan_height = 300
        u.act({'kind':'move', 'x':bounds['X']+bounds['Width']*.7, 'y':bounds['Y']+400})
        time.sleep(.4)
        start_load = os.getloadavg()[0]
        raw = retry(u.capture, b.pid, actions(), 5.1, OUT/(stem+'-rec') if ROUND == 5 else None,
                    attribution={'scroll_scan':[bounds['X']+bounds['Width']-32, scan_y, scan_height]})
        raw.update({'fixture_id':ident, 'scan_page_y':scan_y,
                    'load_start':start_load, 'load_end':os.getloadavg()[0]})
        deadline = time.monotonic()+4
        while (ident, 'scrolltrace') not in u.Handler.events and time.monotonic() < deadline:
            time.sleep(.05)
        beacon = u.Handler.events.get((ident, 'scrolltrace'))
        if not beacon:
            raise u.Invalid('page-side rAF trace missing')
        record.update(metrics(raw, beacon))
        record.update({'status':'valid', 'load_start':start_load, 'load_end':raw['load_end'],
                       'noisy':max(start_load, raw['load_end'])>4, 'raw':stem+'-raw.json', 'beacon':stem+'-beacon.json'})
    except (u.Invalid, OSError) as error:
        record['reason'] = str(error)
    finally:
        if b.proc:
            record.setdefault('pid',b.pid)
            record.setdefault('identity',b.proc.identity)
            record.setdefault('profile',b.temp.name)
        cleanup(b, record)
        # Persist after releasing the app's temporary footprint. Capturing into
        # memory must not lose a completed trial when the volume is nearly full.
        if raw is not None:
            save(OUT/(stem+'-raw.json'), raw)
        if beacon is not None:
            save(OUT/(stem+'-beacon.json'), beacon)
        save(OUT/(stem+'-result.json'), record)
        print(json.dumps({k:v for k,v in record.items() if k not in ('presented','movement','raf','owned_processes','launch_command')}), flush=True)
    return record


def checks():
    row = lambda pid, name, layer=0: {'kCGWindowOwnerPID':pid, 'kCGWindowOwnerName':name,
             'kCGWindowLayer':layer, 'kCGWindowBounds':{'X':40,'Y':60,'Width':1200,'Height':760}}
    own = row(1, 'benchmark')
    assert u.visible_obstructions(1, [row(2,'Wispr Flow',1000), own]) == []
    cursor = {**row(2,'Window Server',2147483630), 'kCGWindowName':'Cursor'}
    assert u.visible_obstructions(1, [cursor,own]) == []
    assert u.visible_obstructions(1, [row(2,'Window Server',2147483630),own])
    for name in ['Raycast','SecurityAgent','loginwindow','Other']:
        assert len(u.visible_obstructions(1,[row(2,name,1000),own])) == 1
    assert u.visible_obstructions(1,[own,row(2,'Raycast')]) == []
    for offset in [0,12,24,72,120,4320]:
        rgb = bytearray()
        for y in range(240,540):
            n = (y+offset-220)//120
            rgb.extend(PALETTE[n])
        assert decode(rgb,220,240) == offset
    a = actions()
    assert len(a) == 362 and a[0]['phase'] == 1 and a[-1]['phase'] == 4
    assert sum(x['dy'] for x in a) == -4320
    assert all(x['phase'] == 2 and x['dy'] == -12 for x in a[1:-1])
    print('Guard, presentation ruler and phased input checks passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--round', type=int)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.check:
        checks()
        raise SystemExit(0)
    ROUND = args.round
    assert ROUND is not None and 1 <= ROUND <= 14
    DEADLINE = time.monotonic()+480
    u.HELPER = OUT/'scroll-capture'
    original_act = u.act
    u.act = lambda *a, **kw: retry(original_act, *a, **kw)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    server = u.bench.DualStackServer(('::', u.bench.PORT), u.Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # Each condition occupies each serial position twice across ten rounds.
    order = CONDITIONS[(ROUND-1)%5:] + CONDITIONS[:(ROUND-1)%5]
    try:
        for condition in order:
            existing = list(OUT.glob(f'scroll-r{ROUND:02d}-{condition}-a*-result.json'))
            if any(json.loads(p.read_text())['status'] == 'valid' for p in existing):
                continue
            for attempt in range(len(existing)+1, len(existing)+4):
                if time.monotonic() > DEADLINE-45:
                    raise TimeoutError('bounded round deadline')
                result = trial(condition, attempt)
                if result['status'] == 'valid':
                    break
            else:
                raise RuntimeError(f'{condition}: three rejected trials')
    finally:
        server.shutdown()
