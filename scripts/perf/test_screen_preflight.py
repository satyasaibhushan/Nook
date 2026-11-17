import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import uibench


class ScreenPreflightTests(unittest.TestCase):
    def preflight(self, permissions):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root/"capture-helper"
            helper.touch()
            output = root/"result.json"
            with patch.object(sys, "argv", ["uibench", "--out", str(output), "--only", "keyboard"]), patch.object(
                uibench, "HELPER", helper,
            ), patch.object(uibench, "helper", return_value=permissions) as command, patch.object(
                uibench, "Browser",
            ) as browser, patch.object(uibench.bench, "DualStackServer") as server:
                self.assertEqual(uibench.main(), 1)
                command.assert_called_once_with("permissions")
                browser.assert_not_called()
                server.assert_not_called()
            return json.loads(output.read_text())

    def test_locked_desktop_stops_before_starting_browser_or_fixture_server(self):
        result = self.preflight({"screen": True, "accessibility": True, "post_events": True, "unlocked": False})
        for browser in result["browsers"].values():
            self.assertEqual(browser, {"status": "blocked", "reason": "macOS desktop is locked"})

    def test_unlocked_desktop_preserves_missing_permission_diagnostic(self):
        permissions = {"screen": False, "accessibility": True, "post_events": True, "unlocked": True}
        result = self.preflight(permissions)
        for browser in result["browsers"].values():
            self.assertEqual(browser, {"status": "blocked", "reason": f"macOS permission missing: {permissions}"})


if __name__ == "__main__":
    unittest.main()
