import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class BridgeInstallerTests(unittest.TestCase):
    def test_brave_uses_its_macos_chrome_compatibility_directory(self):
        source = Path(__file__).resolve().parents[1] / "Extension"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Daybook.app"
            helper = app / "Contents/MacOS/DaybookVideoBridge"
            helper.parent.mkdir(parents=True)
            helper.write_text("test helper")
            env = {**os.environ, "HOME": str(root / "home")}
            subprocess.run(
                [
                    sys.executable,
                    str(source / "install_bridge.py"),
                    "--browser",
                    "brave",
                    "--app",
                    str(app),
                ],
                env=env,
                check=True,
                capture_output=True,
            )
            native = (
                root
                / "home/Library/Application Support/Google/Chrome/NativeMessagingHosts/local.daybook.video.json"
            )
            manifest = json.loads(native.read_text())
            self.assertEqual(manifest["path"], str(helper.resolve()))
            self.assertEqual(manifest["name"], "local.daybook.video")
            extension = (source / "extension-id.txt").read_text().strip()
            self.assertEqual(
                manifest["allowed_origins"], [f"chrome-extension://{extension}/"]
            )
            self.assertFalse(
                (root / "home/Library/Application Support/BraveSoftware").exists()
            )

    def test_bundled_installer_follows_an_app_moved_to_another_folder(self):
        source = Path(__file__).resolve().parents[1] / "Extension"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Original Location/Daybook.app"
            helper = app / "Contents/MacOS/DaybookVideoBridge"
            helper.parent.mkdir(parents=True)
            helper.write_text("test helper")
            bundled = app / "Contents/Resources/VideoExtension"
            bundled.mkdir(parents=True)
            for name in ["install_bridge.py", "extension-id.txt"]:
                shutil.copy2(source / name, bundled / name)
            env = {**os.environ, "HOME": str(root / "home")}

            def install(location):
                subprocess.run(
                    [
                        sys.executable,
                        str(
                            location
                            / "Contents/Resources/VideoExtension/install_bridge.py"
                        ),
                    ],
                    env=env,
                    check=True,
                    capture_output=True,
                )

            install(app)
            destination = root / "Moved App.app"
            app.rename(destination)
            install(destination)
            native = (
                root
                / "home/Library/Application Support/Google/Chrome/NativeMessagingHosts/local.daybook.video.json"
            )
            manifest = json.loads(native.read_text())
            self.assertEqual(
                manifest["path"],
                str((destination / "Contents/MacOS/DaybookVideoBridge").resolve()),
            )
            self.assertTrue(native.with_suffix(".json.previous").exists())
            self.assertEqual(list(native.parent.glob(".daybook-*.tmp")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
