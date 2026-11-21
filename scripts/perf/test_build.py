import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import experiment


class BuildOutputTests(unittest.TestCase):
    def test_build_rejects_matching_identity_under_a_different_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            applications = root/"Applications"
            applications.mkdir()
            installed = applications/"Nook.app"
            installed.mkdir()
            firmlink = root/"Data"/"Applications"
            outside_bundle = root/"output"/"Nook.app"
            for path in (firmlink, outside_bundle):
                path.mkdir(parents=True)
            real_stat = Path.stat

            def stat_path(path, *args, **kwargs):
                identity = {firmlink: applications, outside_bundle: installed}
                return real_stat(identity.get(path, path), *args, **kwargs)

            with patch.object(experiment, "APPLICATIONS", applications), patch.object(Path, "stat", stat_path):
                for destination in (firmlink/"new", outside_bundle.parent):
                    with self.subTest(destination=destination):
                        with self.assertRaisesRegex(experiment.Invalid, "outside /Applications"):
                            experiment.build_output(destination)

    def test_build_rejects_aliases_of_the_install_directory_and_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            applications = root/"Applications"
            installed = applications/"Nook.app"
            installed.mkdir(parents=True)
            alias = root/"alias"
            alias.symlink_to(applications)
            outside = root/"output"
            outside.mkdir()
            (outside/"Nook.app").symlink_to(installed)

            destinations = [root/"aPpLiCaTiOnS"/"new", alias/"new", outside]
            with patch.object(experiment, "APPLICATIONS", applications), patch.object(
                experiment, "disk_headroom",
            ) as preflight, patch.object(experiment, "exclusive"):
                for destination in destinations:
                    with self.subTest(destination=destination):
                        with self.assertRaisesRegex(experiment.Invalid, "outside /Applications"):
                            experiment.build(destination)
                preflight.assert_not_called()

            tools = root/"bin"
            scripts = root/"scripts/perf"
            tools.mkdir()
            scripts.mkdir(parents=True)
            script = scripts/"build.sh"
            shutil.copyfile(Path(experiment.__file__).with_name("build.sh"), script)
            # Run the real validator with the installed app rooted in the fixture.
            source = Path(experiment.__file__).read_text()
            installed_path = 'APPLICATIONS = Path("/Applications")'
            self.assertIn(installed_path, source)
            (scripts/"experiment.py").write_text(source.replace(installed_path, f"APPLICATIONS = Path({str(applications)!r})"))
            xcodebuild = tools/"xcodebuild"
            xcodebuild.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(root/'build-started'))}\nexit 1\n")
            xcodebuild.chmod(0o700)
            env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}"}
            for destination in destinations:
                with self.subTest(coordinated_destination=destination):
                    result = subprocess.run(["/bin/bash", str(script), str(destination), "--coordinated"],
                                            env=env, capture_output=True, text=True, timeout=5)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("outside /Applications", result.stderr)
            self.assertFalse((root/"build-started").exists())
            self.assertFalse((applications/"new").exists())
            self.assertTrue(installed.is_dir())

            # A destination can change while xcodebuild is running.
            (outside/"Nook.app").unlink()
            xcodebuild.write_text(f"#!/bin/sh\nln -s {shlex.quote(str(installed))} "
                                  f"{shlex.quote(str(outside/'Nook.app'))}\n")
            result = subprocess.run(["/bin/bash", str(script), str(outside), "--coordinated"],
                                    env=env, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("outside /Applications", result.stderr)
            self.assertTrue((outside/"Nook.app").is_symlink())
