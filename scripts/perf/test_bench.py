import os
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import Mock, patch

import bench
import experiment


class TrialStateTests(unittest.TestCase):
    def test_sigterm_during_bench_cold_launch_removes_trial_state(self):
        app = object.__new__(bench.App)
        app.exe = "/tmp/isolated.app/Contents/MacOS/Nook"
        app.proc = None
        process = Mock()
        process.poll.return_value = None
        states = []

        def launch(args, **kwargs):
            states.append(Path(args[args.index("-NookStateDir") + 1]))
            self.assertTrue(states[-1].is_dir())
            os.kill(os.getpid(), signal.SIGTERM)
            return process

        process.wait.side_effect = lambda timeout: self.assertTrue(states[-1].is_dir())
        # Clean up the fixture even when this test runs against the unfixed code.
        with tempfile.TemporaryDirectory() as root, patch.object(tempfile, "tempdir", root), patch.object(
            bench.subprocess, "Popen", side_effect=launch,
        ), patch.object(bench.time, "sleep"), experiment.cooperative_signals():
            with self.assertRaises(experiment.Interrupted) as error:
                bench.scenario_cold(app, 1)
            self.assertEqual(error.exception.signum, signal.SIGTERM)
            self.assertFalse(states[0].exists())
            process.terminate.assert_called_once()
            process.wait.assert_called_once_with(5)
            self.assertIsNone(app.proc)
