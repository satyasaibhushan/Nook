import unittest
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

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
        self.raw["frames"][0]["t"] = 9.7
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
