#!/usr/bin/env python3
"""Register the local video helper without changing browser settings."""

import argparse
import json
import pathlib
import tempfile


def find_app(extension_dir, requested_app=None):
    if requested_app is not None:
        return requested_app.expanduser().resolve()
    bundled_app = next(
        (parent for parent in extension_dir.parents if parent.suffix == ".app"), None
    )
    return bundled_app or extension_dir.parent / ".build" / "Daybook.app"


def install_bridge(browser, app, extension_dir):
    host = (app / "Contents/MacOS/DaybookVideoBridge").resolve()
    if not host.is_file():
        raise FileNotFoundError(
            "Build Daybook.app first, or pass --app /path/to/Daybook.app"
        )

    # Brave on macOS uses Chrome's native-messaging compatibility directory.
    browser_folders = {
        "brave": "Google/Chrome",
        "chrome": "Google/Chrome",
        "edge": "Microsoft Edge",
    }
    destination = (
        pathlib.Path.home()
        / "Library/Application Support"
        / browser_folders[browser]
        / "NativeMessagingHosts"
    )
    destination.mkdir(parents=True, exist_ok=True)
    extension_id = (extension_dir / "extension-id.txt").read_text().strip()
    manifest = {
        "name": "local.daybook.video",
        "description": "Daybook local video playback bridge",
        "path": str(host),
        "type": "stdio",
        "allowed_origins": ["chrome-extension://" + extension_id + "/"],
    }
    target = destination / "local.daybook.video.json"
    contents = json.dumps(manifest, indent=2) + "\n"
    if target.exists() and target.read_text() != contents:
        target.with_suffix(".json.previous").write_bytes(target.read_bytes())
    # Never expose a partially written manifest to a connecting browser.
    with tempfile.NamedTemporaryFile(
        mode="w", dir=destination, prefix=".daybook-", suffix=".tmp", delete=False
    ) as temporary:
        temporary.write(contents)
        staged = pathlib.Path(temporary.name)
    try:
        staged.chmod(0o644)
        staged.replace(target)
    finally:
        staged.unlink(missing_ok=True)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--browser", choices=["brave", "chrome", "edge"], default="brave"
    )
    parser.add_argument("--app", type=pathlib.Path)
    arguments = parser.parse_args()
    extension_dir = pathlib.Path(__file__).resolve().parent
    try:
        install_bridge(
            arguments.browser, find_app(extension_dir, arguments.app), extension_dir
        )
    except OSError as error:
        parser.exit(1, str(error) + "\n")
    print("Installed local bridge for " + arguments.browser + ".")
    print(
        "Next: load the extension folder in your browser, then pair it using Daybook Settings."
    )


if __name__ == "__main__":
    main()
