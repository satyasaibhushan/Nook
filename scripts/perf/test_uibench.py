import unittest
import base64
from contextlib import contextmanager
import errno
import json
import os
import signal
import subprocess
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import Mock, call, patch

import experiment
import uibench
from uibench_evidence import Evidence, recognize_input, validate_timeline, write_json


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.raw = {
            "clock": {"wall_seconds": 1_800_000_010, "host_seconds": 10},
            "events": [{"t": 9}],
            "frames": [{"t": 9.51, "green": .3}],
        }
        self.browser = SimpleNamespace(pid=42, page=lambda **kwargs: "calibration",
                                       capture=Mock(return_value=self.raw))

    def validate(self):
        with patch.object(uibench, "window", return_value={"kCGWindowBounds": {
            "X": 0, "Y": 0, "Width": 1000, "Height": 800,
        }}), patch.dict(
            uibench.Handler.events,
            {("calibration", "color"): {"wall": 1_800_000_009_500}}, clear=True,
        ), patch.object(uibench.time, "time", return_value=1_800_000_010), patch.object(
            uibench.time, "monotonic", return_value=187_522,
        ):
            return uibench.validation(self.browser, None)

    def test_uses_native_anchor_when_python_clock_has_a_different_epoch(self):
        result = self.validate()
        self.assertEqual(result["status"], "valid")
        self.assertAlmostEqual(result["observed_page_delay_ms"], 500)
        self.assertAlmostEqual(result["capture_after_known_change_ms"], 10)

    def test_native_anchor_keeps_capture_error_guard(self):
        self.raw["frames"][0]["t"] = 9.69
        with self.assertRaisesRegex(uibench.Invalid, "synthetic calibration failed"):
            self.validate()


class HelperOptionsTests(unittest.TestCase):
    def setUp(self):
        self.helper_patch = patch.object(uibench, "HELPER")
        self.timeout_patch = patch.object(uibench, "HELPER_TIMEOUT")
        self.helper_patch.start()
        self.timeout_patch.start()
        self.addCleanup(self.helper_patch.stop)
        self.addCleanup(self.timeout_patch.stop)
        lock_directory = tempfile.TemporaryDirectory()
        self.addCleanup(lock_directory.cleanup)
        lock_patch = patch.object(experiment, "LOCK_PATH", Path(lock_directory.name)/"lock")
        disk_patch = patch.object(uibench, "disk_headroom", return_value=[])
        lock_patch.start()
        disk_patch.start()
        self.addCleanup(lock_patch.stop)
        self.addCleanup(disk_patch.stop)

    def test_custom_helper_is_not_rebuilt_and_uses_requested_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory)/"approved-capture"
            helper.write_text("#!/bin/sh\nexit 0\n")
            helper.chmod(0o700)
            with patch.object(uibench, "run", return_value=json.dumps({"screen": False})) as run:
                result = uibench.main([
                    "--out", str(Path(directory)/"out.json"), "--only", "keyboard",
                    "--helper-path", str(helper), "--helper-timeout", "650",
                ])
            self.assertEqual(result, 1)
            run.assert_called_once_with([helper.resolve(), "permissions"], timeout=650)

    def test_report_lists_temporary_and_shared_stores(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory)/"capture"
            helper.touch()
            helper.chmod(0o700)
            output = Path(directory)/"out.json"
            with patch.object(uibench, "run", return_value=json.dumps({"screen": False})):
                result = uibench.main([
                    "--out", str(output), "--only", "cold", "--helper-path", str(helper),
                ])
            self.assertEqual(result, 1)
            manifest = json.loads(output.read_text())["isolation_manifest"]

        self.assertIn("warm", manifest["filesystem_cache"])
        stores = manifest["browsers"]
        self.assertEqual(stores["nook"]["temporary"], ["Tab state under -NookStateDir"])
        self.assertTrue(any("history" in store and "com.gstudios.nook.perf/default.store" in store
                            for store in stores["nook"]["bundle_shared"]))
        self.assertTrue(any("FaviconCache" in store for store in stores["nook"]["shared"]))
        self.assertTrue(stores["chrome"]["temporary"])
        self.assertTrue(stores["zen"]["temporary"])
        self.assertTrue(stores["arc"]["shared"])

    def test_custom_helper_keeps_video_in_the_served_fixture_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root/"external"/"approved-capture"
            helper.parent.mkdir()
            helper.touch(mode=0o700)
            video = root/"fixtures"/"loop.mp4"

            def command(args, **kwargs):
                self.assertEqual(args[1], "video")
                self.assertTrue(video.parent.is_dir())
                Path(args[2]).write_bytes(b"video fixture")
                return '{"ok":true}'

            with patch.object(uibench, "VIDEO", video), patch.object(uibench, "run", side_effect=command) as run, patch.object(
                uibench, "desktop_preflight",
            ), patch.object(uibench, "capture_desktop"):
                result = uibench.main([
                    "--out", str(root/"out.json"), "--only", "resources", "--browsers", "chrome",
                    "--helper-path", str(helper), "--phase", "capture",
                ])
                reply = Mock()
                uibench.Handler.do_GET(SimpleNamespace(path="/ui/video.mp4", reply=reply))
            self.assertEqual(result, 0)
            run.assert_called_once_with([helper.resolve(), "video", video], timeout=uibench.DEFAULT_HELPER_TIMEOUT)
            reply.assert_called_once_with("video/mp4", b"video fixture")
            self.assertFalse((helper.parent/"loop.mp4").exists())

    def test_long_helper_timeout_keeps_cold_capture_limit(self):
        browser = SimpleNamespace(pid=42, launch_time=0, launch=Mock(), cleanup=Mock())
        raw = {"rect": [0, 0, 1000, 800], "frames": [{
            "t": 1, "pixels": base64.b64encode(bytes(160*100*3)).decode(),
        }]}
        process = SimpleNamespace(
            returncode=0, communicate=Mock(return_value=(json.dumps(raw), "")), poll=Mock(return_value=0),
        )

        def launch_capture(args, **kwargs):
            spec = json.loads(Path(args[-1]).read_text())
            Path(spec["ready_file"]).touch()
            return process

        with tempfile.TemporaryDirectory() as directory, patch.object(
            uibench, "HELPER_TIMEOUT", 650,
        ), patch.object(uibench, "Browser", return_value=browser), patch.object(
            uibench.subprocess, "Popen", side_effect=launch_capture,
        ), patch.object(uibench.time, "sleep"), patch.object(uibench, "wait_for_clear_window", return_value={
            "kCGWindowBounds": {"X": 0, "Y": 0, "Width": 1000, "Height": 800},
        }):
            entry = {}
            uibench.cold_launch("nook", "unused", 1, None, evidence=Evidence(Path(directory), "inspected"), entry=entry)
            self.assertEqual(entry["runs"][0]["status"], "valid")
        process.communicate.assert_called_once_with(timeout=15)
        browser.cleanup.assert_called_once()
        self.assertEqual(entry["runs"][0]["first_full_window_ms"], 1000)
        self.assertEqual(entry["label"], "Fresh process with warm filesystem cache and shared SwiftData history")
        report = uibench.markdown({"browsers": {"nook": {"cold_launch": entry}}})
        self.assertIn("Fresh-process full window ms", report)
        self.assertIn(entry["label"], report)
        self.assertIn("`cold_launch` and `first_full_window_ms`", report)

    def test_rejects_missing_or_nonexecutable_helper_before_running_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory)/"not-executable"
            for exists in (False, True):
                if exists:
                    helper.write_text("#!/bin/sh\n")
                with self.subTest(exists=exists), patch.object(uibench, "run") as run:
                    with self.assertRaises(SystemExit), patch("sys.stderr"):
                        uibench.main(["--out", "unused.json", "--helper-path", str(helper)])
                    run.assert_not_called()

    def test_rejects_nonpositive_or_nonfinite_timeout_before_running_commands(self):
        for value in ("0", "-1", "nan", "inf"):
            with self.subTest(value=value), patch.object(uibench, "run") as run:
                with self.assertRaises(SystemExit), patch("sys.stderr"):
                    uibench.main(["--out", "unused.json", "--helper-timeout", value])
                run.assert_not_called()


def row(pid=42, name="Nook", layer=0, number=1, bounds=(50, 50, 1000, 800), title=None, alpha=1):
    result = {"kCGWindowOwnerPID": pid, "kCGWindowOwnerName": name, "kCGWindowLayer": layer,
              "kCGWindowNumber": number, "kCGWindowBounds": dict(zip(uibench.WINDOW_KEYS, bounds)),
              "kCGWindowAlpha": alpha}
    if title is not None:
        result["kCGWindowName"] = title
    return result


def raw_capture():
    return {
        "start": 10, "end": 12, "visibility_samples": 120,
        "events": [{"action": {"kind": "key"}, "t": 10.5, "action_start": 10.5,
                    "key_event_ns": 10_510_000_000, "key_post_time": 10.511, "key_post_return": 10.512}],
        "frames": [{"t": 9.99, "changed": 0}, {"t": 10.55, "changed": .1}, {"t": 11, "changed": 0}],
    }


class ExperimentTests(unittest.TestCase):
    def test_low_disk_rejects_before_helper_build_and_lists_only_idle_caches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current, idle, busy = (root/name for name in ("current", "idle", "busy"))
            for path in (current, idle, busy):
                (path/"build").mkdir(parents=True)
            listing = "".join(f"worktree {path}\0\0" for path in (current, idle, busy))
            with patch.object(experiment.shutil, "disk_usage", return_value=SimpleNamespace(free=1)), patch.object(
                experiment.subprocess, "check_output", return_value=listing,
            ), patch.object(experiment.subprocess, "run", return_value=SimpleNamespace(stdout=f"n{busy}/build/bin\n")):
                with self.assertRaisesRegex(experiment.Invalid, f"need 3 GiB.*{idle}/build") as error:
                    experiment.disk_headroom([current/"build"], 3, root=current)
                self.assertNotIn(str(busy), str(error.exception))
                self.assertTrue((idle/"build").is_dir())
            with patch.object(uibench, "disk_headroom", side_effect=experiment.Invalid("low disk")), patch.object(
                uibench, "prepare_helper",
            ) as compile_helper:
                self.assertEqual(uibench.main(["--out", str(root/"out.json")]), 1)
                compile_helper.assert_not_called()

    def test_evidence_preflight_rejects_non_file(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(experiment.Invalid, "not a regular file"):
                experiment.check_evidence([Path(directory)])

    def test_lock_contends_across_processes_and_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory)/"desktop.lock"
            with patch.object(experiment, "LOCK_PATH", lock):
                script = ("from pathlib import Path; import experiment, sys; "
                          "experiment.LOCK_PATH = Path(sys.argv[1]); "
                          "exec('with experiment.exclusive(wait=0): pass')")
                args = [os.sys.executable, "-c", script, str(lock)]
                env = {**os.environ, "PYTHONPATH": str(Path(uibench.__file__).parent)}
                with experiment.exclusive(wait=0):
                    child = subprocess.run(args, env=env, capture_output=True, text=True, timeout=5)
                    self.assertNotEqual(child.returncode, 0)
                    self.assertIn("desktop experiment busy", child.stderr)
                child = subprocess.run(args, env=env, capture_output=True, text=True, timeout=5)
                self.assertEqual(child.returncode, 0)

    def test_queued_run_checks_load_after_lock_acquisition(self):
        events = []

        @contextmanager
        def queued(*args):
            events.append("waited")
            yield

        def check_load(limit):
            self.assertEqual(events, ["waited", "preflight"])
            raise experiment.Invalid("load1 rose while waiting")

        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)/"out.json"
            with patch.object(uibench, "exclusive", queued), patch.object(uibench, "disk_headroom"), patch.object(
                uibench, "desktop_preflight", side_effect=lambda *args: events.append("preflight"),
            ), patch.object(uibench, "check_load", check_load), patch.object(uibench, "Browser") as browser:
                status = uibench.main(["--phase", "preflight", "--out", str(out)])
                self.assertEqual(status, 1)
                self.assertEqual(json.loads((out.parent/"out-preflight.json").read_text())["preflight"]["reason"],
                                 "load1 rose while waiting")
                browser.assert_not_called()


class TimingTests(unittest.TestCase):
    def test_reports_action_and_key_to_frame_against_same_host_clock(self):
        raw = raw_capture()
        validate_timeline(raw)
        result = uibench.analyze(raw)
        self.assertAlmostEqual(result["first_change_ms"], 50)
        self.assertAlmostEqual(result["action_start_ms"], 50)
        self.assertAlmostEqual(result["key_to_frame_ms"], 40)

    def test_rejects_impossible_key_and_frame_ordering(self):
        for event_field, value in (("key_event_ns", 10_490_000_000), ("key_post_time", 10.509),
                                   ("key_post_return", 10.509)):
            with self.subTest(event_field=event_field):
                raw = raw_capture()
                raw["events"][0][event_field] = value
                with self.assertRaisesRegex(uibench.Invalid, "timestamp ordering"):
                    validate_timeline(raw)
        raw = raw_capture()
        raw["frames"][1]["t"] = 10.5105
        with self.assertRaisesRegex(uibench.Invalid, "precedes the target key post"):
            uibench.analyze(raw)
        raw = raw_capture()
        raw["frames"].reverse()
        with self.assertRaisesRegex(uibench.Invalid, "run backwards"):
            validate_timeline(raw)

    def test_legacy_action_latency_has_no_key_latency(self):
        raw = raw_capture()
        raw["events"] = [{"t": 10.5}]
        self.assertIsNone(uibench.analyze(raw)["key_to_frame_ms"])


class ObstructionTests(unittest.TestCase):
    def test_transient_obstruction_invalidates_capture_with_clear_endpoints(self):
        raw = raw_capture()
        raw["obstruction"] = {"t": 10.55, "reason": "Notification Center (pid 43, layer 25)"}
        evidence = Mock()
        with patch.object(uibench, "wait_for_clear_window", return_value=row()), patch.object(
            uibench, "spec_call", return_value=raw,
        ) as native:
            with self.assertRaisesRegex(uibench.Obstruction, "during capture.*Notification Center"):
                uibench.capture(42, allowed_owner=56, evidence=evidence)
        self.assertEqual(native.call_args.args[1]["allowed_owner"], 56)
        evidence.collect.assert_called_once()

    def test_capture_requires_in_stream_window_samples(self):
        raw = raw_capture()
        del raw["visibility_samples"]
        with patch.object(uibench, "wait_for_clear_window", return_value=row()), patch.object(
            uibench, "spec_call", return_value=raw,
        ):
            with self.assertRaisesRegex(uibench.Invalid, "no in-stream window visibility samples"):
                uibench.capture(42, evidence=Mock())

    def test_transparent_os_container_does_not_hide_opaque_prompt_from_same_owner(self):
        target = row()
        container = row(10, "Notification Center", 24, 2, (0, 0, 1920, 1080))
        prompt = row(10, "Notification Center", 25, 3, (200, 200, 400, 300), "Permission")
        with patch.object(uibench, "helper", side_effect=[[container, prompt, target], {"transparent": True}]) as helper, patch.object(
            uibench, "log",
        ) as log:
            with self.assertRaisesRegex(uibench.Obstruction, "Notification Center.*layer 25"):
                uibench.wait_for_clear_window(42, retry=False)
            self.assertEqual(helper.call_args.args, ("transparent-container", 2, 10))
            log.assert_called_once()
            self.assertIn("layer 25", log.call_args.args[0])

    def test_full_display_dock_fails_closed_without_transparency_proof(self):
        target = row()
        container = row(10, "Dock", 20, 2, (0, 0, 1920, 1080))
        with patch.object(uibench, "helper", side_effect=[[container, target], {"transparent": False}]):
            with self.assertRaisesRegex(uibench.Obstruction, "Dock.*layer 20"):
                uibench.wait_for_clear_window(42, retry=False)

    def test_only_owned_activation_occluder_is_exempt(self):
        target = row()
        visible = [row(60, "Prompt", 3, 7), row(56, "uibench-capture", 0, 6), target]
        self.assertEqual(list(uibench.obstruction_rows(42, target, visible, allowed_owner=56)), [visible[0]])
        self.assertEqual(list(uibench.obstruction_rows(42, target, [target, visible[0]])), [])

    def test_reports_obstruction_before_retry_and_obeys_helper_budget(self):
        target = row()
        blocked = [row(43, "Prompt", 3, 2), target]
        events = []
        with patch.object(uibench, "HELPER_TIMEOUT", .4), patch.object(
            uibench, "helper", side_effect=[blocked, [target]],
        ) as helper, patch.object(uibench.time, "monotonic", side_effect=[1, 1, 1, 1.2]), patch.object(
            uibench.time, "sleep", side_effect=lambda delay: events.append(("sleep", delay)),
        ), patch.object(uibench, "log", side_effect=lambda message: events.append(("log", message))):
            self.assertEqual(uibench.wait_for_clear_window(42), target)
            self.assertEqual([event[0] for event in events], ["log", "sleep"])
            self.assertLessEqual(helper.call_args.kwargs["timeout"], .4)
            self.assertGreater(helper.call_args.kwargs["timeout"], 0)


class CaptureModeTests(unittest.TestCase):
    def test_scroll_samples_resources_before_inspecting_captured_rows(self):
        events = []
        raw = raw_capture()
        raw["events"][0]["action"] = {"kind": "scroll"}
        browser = SimpleNamespace(
            pid=42, ax_mode="none", activate=Mock(), page=Mock(),
            resources=Mock(side_effect=lambda: events.append("resources") or {"cpu_s": 1}),
            capture=Mock(side_effect=lambda *a, **kw: events.append("capture") or raw),
        )
        with patch.object(uibench, "window", return_value=row()), patch.object(uibench, "act"), patch.object(
            uibench, "analyze", side_effect=lambda *a: events.append("analyze") or {},
        ):
            trial = uibench.scenario(browser, "scroll", 0, None)
        self.assertEqual(events, ["resources", "capture", "resources", "analyze"])
        self.assertEqual(trial["cpu_percent"], 0)

    def test_ax_none_refuses_to_send_any_target_accessibility_command(self):
        browser = object.__new__(uibench.Browser)
        browser.ax_mode = "none"
        browser.pid = 42
        with patch.object(uibench, "helper") as helper:
            for operation in (browser.ax, browser.owns_current_tab, lambda: browser.inspect("resize")):
                with self.assertRaisesRegex(uibench.Invalid, "--ax-mode none"):
                    operation()
            helper.assert_not_called()

    def test_empty_ax_tree_retries_then_reports_instrumentation(self):
        browser = object.__new__(uibench.Browser)
        browser.ax_mode = "inspected"
        browser.pid = 42
        with patch.object(uibench, "helper", side_effect=[[], [{"AXRole": "AXApplication"}]]) as helper, patch.object(
            uibench.time, "sleep",
        ):
            self.assertEqual(browser.ax(), [{"AXRole": "AXApplication"}])
            self.assertEqual(helper.call_count, 2)
        with patch.object(uibench, "helper", return_value=[]) as helper, patch.object(uibench.time, "sleep"):
            with self.assertRaises(uibench.InstrumentationUnavailable):
                browser.ax()
            self.assertEqual(helper.call_count, 3)

    def test_navigation_parks_pointer_before_keyboard(self):
        browser = object.__new__(uibench.Browser)
        browser.name, browser.pid, browser.owned_tabs = "nook", 42, 0
        browser.activate = Mock()
        setup = Mock()
        with patch.object(uibench, "helper", return_value={"pid": 42}), patch.object(
            uibench, "park_pointer", setup.park,
        ), patch.object(uibench, "act", setup.act), patch.object(uibench.time, "sleep"):
            browser.navigate("http://localhost/")
        self.assertEqual(setup.mock_calls[0], call.park(42))
        self.assertEqual(setup.mock_calls[1], call.act(uibench.key("escape")))

    def test_readiness_capture_records_browser_beacon_without_ax_or_ocr(self):
        browser = SimpleNamespace(name="nook", pid=42, ax_mode="none", ax=Mock(), capture=Mock(),
                                  url=lambda: ("http://localhost/ui/page?id=proof", "proof"), close_tab=Mock())
        captured = raw_capture()
        browser.capture.return_value = captured
        readiness = {}
        with patch.object(uibench, "act"), patch.object(uibench, "park_pointer"), patch.object(
            uibench, "wait_for_beacon", return_value={"id": "proof", "kind": "load"},
        ):
            uibench.command_readiness(browser, row()["kCGWindowBounds"], None, readiness)
        browser.ax.assert_not_called()
        self.assertEqual(readiness["capture_status"], "captured")
        self.assertEqual(readiness["browser_status"], "responsive")
        self.assertEqual(readiness["recognition"], {"status": "pending"})
        self.assertIs(readiness["capture"], captured)
        self.assertLess(browser.capture.call_args.kwargs["input_region"][3], 800)
        self.assertTrue(any(a.get("text") == "http://localhost/ui/page?id=proof" for a in browser.capture.call_args.args[0]))


class PersistenceTests(unittest.TestCase):
    def test_ps_timeout_after_launch_still_terminates_pid_before_profile_cleanup(self):
        browser = object.__new__(uibench.Browser)
        browser.name = "chrome"
        browser.path = Path("/tmp/isolated.app")
        browser.proc = browser.pid = None
        browser.closed = False
        browser.temp = Mock()
        alive = True
        signals = []

        def kill(pid, signum):
            nonlocal alive
            self.assertEqual(pid, 42)
            if not alive:
                raise ProcessLookupError
            if signum:
                signals.append(signum)
                alive = False

        browser.temp.cleanup.side_effect = lambda: self.assertFalse(alive)
        with patch.object(uibench, "spec_call", return_value={"pid": 42, "start": 10}), patch.object(
            uibench, "run", side_effect=subprocess.TimeoutExpired("ps", 2),
        ), patch.object(uibench.os, "kill", side_effect=kill):
            with self.assertRaises(subprocess.TimeoutExpired):
                browser.spawn(["isolated"], {})
            browser.cleanup()
        self.assertEqual(signals, [signal.SIGTERM])
        browser.temp.cleanup.assert_called_once()

    def test_rejected_capture_preserves_raw_and_artifacts_after_cleanup(self):
        raw = raw_capture()
        raw["artifacts"] = {"last.png": base64.b64encode(b"rejected").decode()}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = Evidence(root/"ocr", "none")
            entry = {}
            with evidence.attach(entry), patch.object(
                uibench, "wait_for_clear_window", side_effect=[row(), uibench.Obstruction("prompt")],
            ), patch.object(uibench, "spec_call", return_value=raw):
                with self.assertRaisesRegex(uibench.Obstruction, "prompt"):
                    uibench.capture(42, record=root/"trial", evidence=evidence)
            self.assertFalse((root/"trial").exists())
            self.assertEqual(entry["captures"][0]["events"][0]["key_event_ns"], 10_510_000_000)
            self.assertEqual(entry["captures"][0]["ax_mode"], "none")
            self.assertEqual(evidence.flush(), {})
            self.assertEqual((root/"trial"/"last.png").read_bytes(), b"rejected")

    def test_enospc_artifact_failure_does_not_destroy_the_raw_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = Evidence(root/"ocr", "none")
            raw = raw_capture()
            raw["artifacts"] = {"last.png": base64.b64encode(b"pixels").decode()}
            evidence.collect(raw, root/"trial")
            path = root/"raw.json"
            write_json(path, raw)
            with patch("uibench_evidence.write_atomic", side_effect=OSError(errno.ENOSPC, "disk full")):
                failures = evidence.flush()
            self.assertIn("disk full", failures[str(root/"trial"/"last.png")])
            self.assertEqual(json.loads(path.read_text())["events"], raw["events"])

    def test_sigterm_after_native_capture_still_runs_owned_cleanup_and_persists_raw(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root/"out.json"
            args = uibench.parse_args(["--out", str(path), "--only", "navigate", "--browsers", "chrome",
                                      "--ax-mode", "none", "--phase", "capture"])
            result = uibench.new_result(args)
            evidence = Evidence(root/"ocr", "none")
            browser = SimpleNamespace(
                evidence=evidence, name="chrome", pid=42, version="test", launch=Mock(), page=Mock(),
                cleanup=Mock(side_effect=lambda: self.assertFalse(path.exists())),
            )

            def collect(*args, **kwargs):
                raw = raw_capture()
                os.kill(os.getpid(), signal.SIGTERM)
                return raw

            def scenario(*args):
                uibench.capture(42, evidence=evidence)

            with uibench.cooperative_signals(), patch.object(uibench, "Browser", return_value=browser), patch.object(
                uibench, "validation", return_value={"status": "valid"},
            ), patch.object(uibench.bench, "DualStackServer"), patch.object(
                uibench.bench, "forget_favicons",
            ), patch.object(uibench.subprocess, "run", return_value=SimpleNamespace(stdout="")), patch.object(
                uibench, "run", return_value="macOS",
            ), patch.object(uibench, "check_load", return_value=0.5), patch.object(uibench, "wait_for_clear_window", return_value=row()), patch.object(
                uibench, "spec_call", side_effect=collect,
            ), patch.object(uibench, "scenario", side_effect=scenario):
                with self.assertRaises(experiment.Interrupted):
                    uibench.capture_desktop(args, result, evidence)
            browser.cleanup.assert_called_once()
            saved = json.loads(path.read_text())
            trial = saved["browsers"]["chrome"]["scenarios"]["navigate"]["runs"][0]
            self.assertEqual(trial["status"], "interrupted")
            self.assertEqual(trial["captures"][0]["events"][0]["key_event_ns"], 10_510_000_000)

    def test_signal_during_launch_handoff_registers_owned_process(self):
        browser = object.__new__(uibench.Browser)
        browser.path = Path("/tmp/isolated.app")
        process = Mock(pid=42)

        def spawn(*args):
            os.kill(os.getpid(), signal.SIGTERM)
            return {"pid": 42, "start": 10}

        with uibench.cooperative_signals(), patch.object(uibench, "spec_call", side_effect=spawn), patch.object(
            uibench, "OwnedProcess", return_value=process,
        ):
            with self.assertRaises(experiment.Interrupted):
                browser.spawn(["isolated"], {})
        self.assertIs(browser.proc, process)
        self.assertEqual(browser.pid, 42)

    def test_signal_during_occluder_handoff_stops_the_child(self):
        browser = SimpleNamespace(pid=42, ax_mode="none", activate=Mock(), page=Mock(), capture=Mock())
        process = SimpleNamespace(pid=43, poll=Mock(return_value=None), terminate=Mock(), communicate=Mock())

        def spawn(*args, **kwargs):
            os.kill(os.getpid(), signal.SIGTERM)
            return process

        with uibench.cooperative_signals(), patch.object(uibench, "window", return_value=row()), patch.object(
            uibench, "act",
        ), patch.object(uibench.time, "sleep"), patch.object(uibench.subprocess, "Popen", side_effect=spawn):
            with self.assertRaises(experiment.Interrupted):
                uibench.scenario(browser, "activate", 0, None)

        process.terminate.assert_called_once()
        process.communicate.assert_called_once_with(timeout=5)
        browser.capture.assert_not_called()


class OfflineAnalysisTests(unittest.TestCase):
    def readiness(self, path):
        capture = raw_capture()
        capture.update(input_evidence=str(path), input_frame_times=[10.64])
        capture["events"].append({"t": 10.6, "action": {"kind": "text"}})
        return {"capture": capture, "capture_status": "captured", "browser_status": "responsive",
                "functional_input": {"kind": "load", "id": "expected"}, "recognition": {"status": "pending"}}

    def test_offline_ocr_timeout_preserves_responsive_trial_and_saved_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root/"crop.json"
            evidence.touch()
            readiness = self.readiness(Path(evidence.name))
            trial = {"status": "valid", **uibench.analyze(raw_capture()),
                     "raw": {**raw_capture(), "readiness": readiness}}
            data = {"capture_status": "complete", "requested_runs": 1, "blockers": [],
                    "browsers": {"nook": {"scenarios": {"command": {"runs": [trial]}}}}}
            out = root/"out.json"
            write_json(out, data)

            def timeout(command, path, **kwargs):
                self.assertEqual(command, "ocr")
                self.assertEqual(Path(path), evidence.resolve())
                saved = json.loads(out.read_text())["browsers"]["nook"]["scenarios"]["command"]["runs"][0]
                self.assertEqual(saved["raw"]["readiness"]["functional_input"]["id"], "expected")
                self.assertEqual(saved["raw"]["readiness"]["recognition"]["status"], "pending")
                self.assertEqual(kwargs["timeout"], .1)
                raise subprocess.TimeoutExpired("ocr", .1)

            with patch.object(experiment, "LOCK_PATH", root/"lock"), patch.object(
                uibench, "prepare_helper",
            ), patch.object(uibench, "helper", side_effect=timeout) as helper, patch.object(uibench, "Browser") as browser:
                status = uibench.main(["--phase", "analyze", "--out", str(out), "--ocr-timeout", ".1"])
            self.assertEqual(status, 0)
            helper.assert_called_once()
            browser.assert_not_called()
            entry = json.loads(out.read_text())["browsers"]["nook"]["scenarios"]["command"]
            self.assertEqual(entry["status"], "valid")
            self.assertEqual(entry["readiness_counts"]["recognition"], {"timeout": 1})
            self.assertEqual(entry["readiness_counts"]["browser_status"], {"responsive": 1})
            self.assertEqual(entry["runs"][0]["raw"]["readiness"]["capture_status"], "captured")

    def test_recognition_distinguishes_no_match_invalid_clock_and_capture_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"crop.json"
            path.touch()
            readiness = self.readiness(path)
            match = recognize_input(readiness, lambda _: {"first_text_frame": 10.64})
            self.assertEqual(match["status"], "matched")
            self.assertAlmostEqual(match["action_start_ms"], 140)
            self.assertAlmostEqual(match["key_to_frame_ms"], 130)
            self.assertEqual(recognize_input(readiness, lambda _: {"first_text_frame": None})["status"], "no_match")
            self.assertEqual(recognize_input(readiness, lambda _: {"first_text_frame": 10.59})["status"], "failed")
            readiness["capture_status"] = "failed"
            recognize = Mock()
            self.assertEqual(recognize_input(readiness, recognize)["status"], "skipped")
            recognize.assert_not_called()


if __name__ == "__main__":
    unittest.main()
