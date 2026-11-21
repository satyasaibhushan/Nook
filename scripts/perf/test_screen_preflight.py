import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import experiment
import uibench


class ScreenPreflightTests(unittest.TestCase):
    def preflight(self, permissions, *options, footprint=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root/"capture-helper"
            helper.touch(mode=0o700)
            output = root/"result.json"
            output.write_text("existing capture")
            commands = {"permissions": permissions, "footprint": footprint or {}, "windows": []}
            with patch.object(experiment, "LOCK_PATH", root/"lock"), patch.object(
                uibench, "disk_headroom", return_value=[],
            ), patch.object(uibench, "helper", side_effect=lambda command, *a: commands[command]) as command, patch.object(
                uibench, "Browser",
            ) as browser, patch.object(uibench.bench, "DualStackServer") as server:
                status = uibench.main(["--phase", "preflight", "--out", str(output), "--only", "keyboard",
                                       "--helper-path", str(helper), "--max-load1", "1000", *options])
                browser.assert_not_called()
                server.assert_not_called()
            self.assertEqual(output.read_text(), "existing capture")
            report = root/"result-preflight.json"
            return status, json.loads(report.read_text()), [c.args[0] for c in command.call_args_list]

    def test_locked_desktop_stops_before_process_inspection_and_capture(self):
        status, result, commands = self.preflight({"screen": True, "accessibility": True,
                                                   "post_events": True, "unlocked": False})
        self.assertEqual(status, 1)
        self.assertEqual(commands, ["permissions"])
        for browser in result["browsers"].values():
            self.assertEqual(browser["status"], "blocked")
            self.assertIn("macOS desktop is locked", browser["reason"])

    def test_missing_screen_permission_identifies_helper_and_profile(self):
        status, result, commands = self.preflight({"screen": False, "accessibility": True,
                                                   "post_events": True, "unlocked": True})
        self.assertEqual(status, 1)
        self.assertEqual(commands, ["permissions"])
        self.assertIn("Screen Recording", result["preflight"]["reason"])
        self.assertIn("permission profile", result["preflight"]["reason"])

    def test_background_console_session_has_separate_diagnostic(self):
        status, result, _ = self.preflight({"console_session": False, "unlocked": False})
        self.assertEqual(status, 1)
        self.assertIn("no active macOS console session", result["preflight"]["reason"])

    def test_inspection_denial_blocks_before_launch(self):
        status, result, commands = self.preflight({
            "screen": True, "accessibility": True, "post_events": True,
            "unlocked": True, "capture_protocol": 3,
        })
        self.assertEqual(status, 1)
        self.assertEqual(commands, ["permissions", "footprint"])
        self.assertIn("kernel footprint query was denied", result["preflight"]["reason"])

    def test_helper_without_in_stream_visibility_is_incompatible(self):
        status, result, commands = self.preflight({
            "screen": True, "accessibility": True, "post_events": True,
            "unlocked": True, "capture_protocol": 2,
        })
        self.assertEqual(status, 1)
        self.assertEqual(commands, ["permissions"])
        self.assertIn("incompatible evidence protocol", result["preflight"]["reason"])

    def test_blocked_summary_path_stops_preflight_before_helper_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            out = root/"result.json"
            out.write_text("existing capture")
            out.with_suffix(".md").mkdir()
            with patch.object(experiment, "LOCK_PATH", root/"lock"), patch.object(
                uibench, "disk_headroom", return_value=[],
            ), patch.object(uibench, "prepare_helper") as prepare:
                status = uibench.main(["--phase", "preflight", "--out", str(out)])

            self.assertEqual(status, 1)
            self.assertEqual(out.read_text(), "existing capture")
            report = json.loads((root/"result-preflight.json").read_text())
            self.assertIn("result.md is not a regular file", report["preflight"]["reason"])
            prepare.assert_not_called()

    def test_pure_mode_needs_posting_permission_but_does_not_require_ax(self):
        import os
        status, result, commands = self.preflight({
            "screen": True, "accessibility": False, "post_events": True,
            "unlocked": True, "capture_protocol": 3,
        }, "--ax-mode", "none", footprint={str(os.getpid()): {"physical_bytes": 123}})
        self.assertEqual(status, 0)
        self.assertEqual(commands, ["permissions", "footprint", "windows"])
        self.assertEqual(result["ax_mode"], "none")
        self.assertTrue(result["preflight"]["process_inspection"])


if __name__ == "__main__":
    unittest.main()
