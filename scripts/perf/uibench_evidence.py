"""Buffer capture artifacts and recognize input from saved crops."""

import base64
from contextlib import contextmanager
import json
import math
from pathlib import Path
import subprocess
import tempfile
import uuid

from experiment import Interrupted, Invalid


def write_atomic(path, write, mode="w"):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    staging = None
    try:
        with tempfile.NamedTemporaryFile(mode=mode, dir=path.parent, delete=False) as stream:
            staging = Path(stream.name)
            write(stream)
        staging.replace(path)
    finally:
        if staging is not None:
            staging.unlink(missing_ok=True)


def write_json(path, data):
    write_atomic(path, lambda stream: json.dump(data, stream, indent=2))


class Evidence:
    def __init__(self, folder, ax_mode):
        self.root = folder.resolve().parent
        self.folder = folder.resolve() / uuid.uuid4().hex
        self.ax_mode = ax_mode
        self.files = {}
        self.captures = None

    @contextmanager
    def attach(self, entry):
        previous, self.captures = self.captures, []
        try:
            yield entry
        except Interrupted as error:
            entry.update(status="interrupted", reason=str(error))
            raise
        finally:
            attached = entry.get("raw") or {}
            ready = attached.get("readiness", {}).get("capture")
            extra = [raw for raw in self.captures if raw is not attached and raw is not ready]
            if extra:
                entry["captures"] = extra
            self.captures = previous

    def collect(self, raw, record=None, still=False, needle=None):
        raw["ax_mode"] = self.ax_mode
        raw["record_dir"] = str(record.resolve()) if record and not still else None
        artifacts = raw.pop("artifacts", {})
        frames = raw.pop("input_frames", [])
        if self.captures is not None:
            self.captures.append(raw)
        if needle:
            raw["input_frame_times"] = [frame["t"] for frame in frames]
            if frames:
                path = self.folder / f"input-{uuid.uuid4().hex}.json"
                raw["input_evidence"] = str(path.relative_to(self.root))
                self.files[path] = {"needle": needle, "frames": frames}
        if record:
            for name, encoded in artifacts.items():
                if name in {"first.png", "last.png", "strip.png"}:
                    path = record if still else record / name
                    self.files[path] = encoded
        return raw

    def flush(self):
        errors = {}
        for path, content in self.files.items():
            try:
                if isinstance(content, dict):
                    write_json(path, content)
                else:
                    data = base64.b64decode(content) if isinstance(content, str) else content
                    write_atomic(path, lambda stream: stream.write(data), "wb")
            except (OSError, ValueError) as error:
                errors[str(path)] = str(error)
        self.files.clear()
        return errors


def event_clock(event, start=None):
    """Return the historical action clock and the actual target key-down clock."""
    if event.get("posted") is False:
        raise Invalid("input was withheld because the owned browser lost focus")
    action = event.get("action_start", event["t"])
    key_ns = event.get("key_event_ns")
    if key_ns is None:
        if event.get("action", {}).get("kind") == "key" and "action_start" in event:
            raise Invalid("target key-down timestamp missing")
        return action, None
    post = event.get("key_post_time")
    if type(key_ns) is not int or key_ns <= 0 or not isinstance(post, (float, int)):
        raise Invalid("invalid target key-down timestamp")
    key = key_ns / 1e9
    returned = event.get("key_post_return", post)
    if (not all(map(math.isfinite, (action, key, post, returned))) or not action <= key <= post <= returned
            or (start is not None and action < start)):
        raise Invalid("invalid action-start, key-down and post timestamp ordering")
    return action, key


def validate_timeline(raw):
    start, end = raw.get("start"), raw.get("end")
    if not (isinstance(start, (int, float)) and isinstance(end, (int, float))
            and math.isfinite(start) and math.isfinite(end) and start <= end):
        raise Invalid("capture start and end timestamps are invalid")
    previous = start
    for event in raw["events"]:
        action, key = event_clock(event, start)
        returned = event.get("key_post_return", event.get("key_post_time"))
        if not previous <= action <= end or (key is not None and returned > end):
            raise Invalid("action timestamps fall outside their capture window or run backwards")
        previous = action
    # The first screen sample can precede the startCapture acknowledgement.
    previous = -math.inf
    for frame in raw["frames"]:
        stamp = frame["t"]
        if not previous <= stamp <= end:
            raise Invalid("frame timestamps fall outside their capture window or run backwards")
        previous = stamp


def recognize_input(readiness, recognize, *, root=Path(".")):
    capture = readiness.get("capture", {})
    if readiness.get("capture_status") != "captured":
        return {"status": "skipped", "reason": "readiness capture failed"}
    evidence = capture.get("input_evidence")
    if not evidence or not (path := root / evidence).is_file():
        return {"status": "failed", "reason": "saved input crops unavailable"}
    try:
        validate_timeline(capture)
        t = recognize(str(path))["first_text_frame"]
        if t is None:
            return {"status": "no_match"}
        action, key = event_clock(capture["events"][0], capture.get("start"))
        first_probe = next(e["t"] for e in capture["events"] if e["action"]["kind"] == "text" and e.get("posted") is not False)
        if t not in capture["input_frame_times"] or not first_probe <= t <= capture["end"]:
            raise Invalid("recognized frame timestamp falls outside the posted input capture")
        result = {"status": "matched", "first_text_frame": t, "action_start_ms": (t-action)*1000}
        if key is not None:
            result["key_to_frame_ms"] = (t-key)*1000
        return result
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "reason": "offline Vision OCR exceeded its deadline"}
    except (Invalid, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        return {"status": "failed", "reason": str(error)}
