import unittest
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


if __name__ == "__main__":
    unittest.main()
