import unittest
import base64
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import Mock, call, patch

import uibench


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.raw = {
            "clock": {"wall_seconds": 1_800_000_010, "host_seconds": 10},
            "events": [{"t": 9}],
            "frames": [{"t": 9.51, "green": .3}],
        }
        self.browser = SimpleNamespace(pid=42, page=lambda **kwargs: "calibration")

    def validate(self):
        with patch.object(uibench, "window", return_value={"kCGWindowBounds": {
            "X": 0, "Y": 0, "Width": 1000, "Height": 800,
        }}), patch.object(uibench, "capture", return_value=self.raw), patch.dict(
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
            helper.write_text("#!/bin/sh\nexit 0\n")
            helper.chmod(0o700)
            video = root/"fixtures"/"loop.mp4"

            def command(args, **kwargs):
                if args[1] == "video":
                    self.assertTrue(video.parent.is_dir())
                    Path(args[2]).write_bytes(b"video fixture")
                return json.dumps({"screen": False})

            with patch.object(uibench, "VIDEO", video), patch.object(uibench, "run", side_effect=command) as run:
                result = uibench.main([
                    "--out", str(root/"out.json"), "--only", "resources",
                    "--helper-path", str(helper),
                ])
                reply = Mock()
                uibench.Handler.do_GET(SimpleNamespace(path="/ui/video.mp4", reply=reply))
            self.assertEqual(result, 1)
            run.assert_has_calls([
                call([helper.resolve(), "video", video], timeout=uibench.DEFAULT_HELPER_TIMEOUT),
                call([helper.resolve(), "permissions"], timeout=uibench.DEFAULT_HELPER_TIMEOUT),
            ])
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

        with patch.object(uibench, "HELPER_TIMEOUT", 650), patch.object(uibench, "Browser", return_value=browser), patch.object(
            uibench.subprocess, "Popen", side_effect=launch_capture,
        ), patch.object(uibench.time, "sleep"), patch.object(uibench, "window", return_value={
            "kCGWindowBounds": {"X": 0, "Y": 0, "Width": 1000, "Height": 800},
        }):
            launch = uibench.cold_launch("nook", "unused", 1, None)
        process.communicate.assert_called_once_with(timeout=15)
        browser.cleanup.assert_called_once()
        self.assertEqual(launch["runs"][0]["first_full_window_ms"], 1000)
        self.assertEqual(launch["label"], "Fresh process with warm filesystem cache and shared SwiftData history")
        report = uibench.markdown({"browsers": {"nook": {"cold_launch": launch}}})
        self.assertIn("Fresh-process full window ms", report)
        self.assertIn(launch["label"], report)
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


if __name__ == "__main__":
    unittest.main()
