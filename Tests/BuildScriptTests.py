"""Regression coverage for replacing a signed executable that is still running."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


class BuildScriptTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="daybook-build-tests-")
        self.base = Path(self.scratch.name)
        self.source = self.base / "source"
        self.source.mkdir()
        project = Path(__file__).resolve().parents[1]
        (self.source / "Resources").mkdir()
        for name in ["Info.plist", "Daybook.entitlements"]:
            shutil.copy2(project / "Resources" / name, self.source / "Resources" / name)
        shutil.copy2(
            os.environ.get("DAYBOOK_TEST_BUILD_SCRIPT", project / "build.sh"),
            self.source / "build.sh",
        )
        (self.source / "Sources/Daybook").mkdir(parents=True)
        (self.source / "Sources/Daybook/Dummy.swift").write_text(
            "// compiler fixture\n"
        )
        (self.source / "Sources/VideoBridge").mkdir()
        (self.source / "Sources/VideoBridge/VideoBridge.swift").write_text(
            "// bridge compiler fixture\n"
        )
        (self.source / "Sources/VideoBridge/Bridge.entitlements").write_text(
            "fixture\n"
        )
        (self.source / "Extension").mkdir()
        (self.source / "Extension/manifest.json").write_text("{}\n")
        self.app = self.base / "Daybook.app"
        self.binary = self.app / "Contents/MacOS/Daybook"
        self.binary.parent.mkdir(parents=True)
        self.tools = self.base / "mock-tools"
        self.tools.mkdir()
        compiler = self.tools / "swiftc"
        compiler.write_text(
            """#!/bin/bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then shift; output="$1"; fi
  shift
done
printf 'fresh executable\\n' > "$output"
"""
        )
        compiler.chmod(0o755)
        merger = self.tools / "lipo"
        merger.write_text(
            """#!/bin/bash
shift
first="$1"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-output" ]; then shift; output="$1"; fi
  shift
done
cp "$first" "$output"
"""
        )
        merger.chmod(0o755)
        signer = self.tools / "codesign"
        signer.write_text("#!/bin/bash\nexit 0\n")
        signer.chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
            DAYBOOK_BUILD_DIR=str(self.base / "build"),
            DAYBOOK_APP_PATH=str(self.app),
        )

    def tearDown(self):
        self.scratch.cleanup()

    def build(self):
        return subprocess.run(
            ["/bin/bash", str(self.source / "build.sh")],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_running_app_is_never_modified(self):
        # A copied Apple platform binary can be killed by macOS before the
        # assertion. Use an ordinary locally built process for this regression.
        subprocess.run(
            ["xcrun", "clang", "-x", "c", "-", "-o", str(self.binary)],
            input="#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n",
            text=True,
            capture_output=True,
            check=True,
        )
        before = hashlib.sha256(self.binary.read_bytes()).digest()
        process = subprocess.Popen([str(self.binary), "30"])
        try:
            listing = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True)
            self.assertIn(str(self.binary), listing)
            result = self.build()
            self.assertNotEqual(
                result.returncode, 0, "build must refuse a running target"
            )
            self.assertIn("Quit Daybook", result.stderr)
            self.assertEqual(hashlib.sha256(self.binary.read_bytes()).digest(), before)
            self.assertIsNone(process.poll(), "the running process must remain alive")
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)

    def test_stopped_app_is_replaced_without_overwriting_its_executable(self):
        self.binary.write_text("previous executable\n")
        old_inode = self.binary.stat().st_ino
        (self.app / "stale-resource").write_text("old bundle file")
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.binary.read_text(), "fresh executable\n")
        self.assertNotEqual(self.binary.stat().st_ino, old_inode)
        self.assertFalse((self.app / "stale-resource").exists())
        self.assertTrue((self.app / "Contents/Info.plist").is_file())

    def test_local_pairing_is_excluded_from_distributed_bundles(self):
        pairing = self.source / "Extension/local-pairing.json"
        pairing.write_text('{"pairingCode":"local-test-only"}')
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(
            (self.app / "Contents/Resources/VideoExtension/local-pairing.json").exists()
        )
        with zipfile.ZipFile(
            self.app / "Contents/Resources/Daybook-Helper.zip"
        ) as archive:
            self.assertFalse(
                any(name.endswith("local-pairing.json") for name in archive.namelist())
            )
        self.assertTrue(pairing.exists())

    def test_default_build_stays_inside_the_repository(self):
        self.binary.write_text("existing app outside repository\n")
        self.env.pop("DAYBOOK_BUILD_DIR")
        self.env.pop("DAYBOOK_APP_PATH")
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            (self.source / ".build/Daybook.app/Contents/MacOS/Daybook").is_file()
        )
        self.assertEqual(self.binary.read_text(), "existing app outside repository\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
