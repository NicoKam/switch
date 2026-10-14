#!/usr/bin/env python3
"""Build this fork using Apple's command line tools, without Sparkle."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Output directory (default: build/local)")
    args = parser.parse_args()
    if platform.system() != "Darwin" or int(platform.mac_ver()[0].split(".")[0]) < 14:
        parser.error("Switch must be built on macOS 14 or later.")
    arch = platform.machine()
    if arch not in ("arm64", "x86_64"):
        parser.error("Unsupported architecture: " + arch)
    repo = Path(__file__).resolve().parents[1]
    source = repo / "Sources" / "Switch"
    resources = source / "Resources"
    output = (args.output or repo / "build" / "local").resolve()
    output.mkdir(parents=True, exist_ok=True)
    run("xcrun", "--find", "swiftc")
    run("xcrun", "--find", "clang")

    translations = {}
    for language in ("en", "zh-Hans"):
        strings = resources / (language + ".lproj") / "Localizable.strings"
        run("plutil", "-lint", strings)
        translations[language] = json.loads(subprocess.check_output([
            "plutil", "-convert", "json", "-o", "-", str(strings),
        ]))
    if translations["en"].keys() != translations["zh-Hans"].keys():
        raise RuntimeError("English and Chinese translation keys differ")

    with tempfile.TemporaryDirectory(prefix=".switch-build-", dir=output) as directory:
        stage = Path(directory)
        app = stage / "Switch.app"
        contents = app / "Contents"
        executable_dir = contents / "MacOS"
        resource_dir = contents / "Resources"
        executable_dir.mkdir(parents=True)
        resource_dir.mkdir()
        exception = stage / "ObjCException.o"
        run("xcrun", "clang", "-c", "-fobjc-arc", "-mmacosx-version-min=14.0",
            source / "ObjCException.m", "-o", exception)
        run("xcrun", "swiftc", "-swift-version", "5", "-O",
            "-target", arch + "-apple-macosx14.0",
            "-import-objc-header", source / "Switch-Bridging-Header.h",
            *sorted(source.glob("*.swift")), exception,
            "-F", "/System/Library/PrivateFrameworks", "-framework", "SkyLight",
            "-o", executable_dir / "Switch")
        for language in translations:
            shutil.copytree(resources / (language + ".lproj"), resource_dir / (language + ".lproj"))
        iconset = stage / "AppIcon.iconset"
        iconset.mkdir()
        for icon in (resources / "Assets.xcassets" / "AppIcon.appiconset").glob("*.png"):
            shutil.copy2(icon, iconset / icon.name)
        run("iconutil", "-c", "icns", iconset, "-o", resource_dir / "AppIcon.icns")

        with (resources / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        commit = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "--short", "HEAD"], text=True).strip()
        dirty = bool(subprocess.check_output([
            "git", "-C", str(repo), "status", "--porcelain", "--untracked-files=normal",
            "--", "Sources/Switch", "scripts/build-local.py",
        ]))
        info.update(CFBundleExecutable="Switch", CFBundleIdentifier="com.sanyamgarg.switch",
                    CFBundleIconFile="AppIcon", CFBundleLocalizations=["en", "zh-Hans"],
                    SwitchForkBuild=True, BuildCommit=commit + ("-dirty" if dirty else ""),
                    BuildDate=datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%MZ"))
        for key in list(info):
            if key.startswith("SU"):
                del info[key]
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        run("plutil", "-lint", contents / "Info.plist")
        run("codesign", "--force", "--sign", "-", "--identifier", info["CFBundleIdentifier"], app)
        run("codesign", "--verify", "--strict", app)
        destination = output / "Switch.app"
        backup = None
        if destination.exists() or destination.is_symlink():
            if not destination.is_dir() or destination.is_symlink():
                raise RuntimeError("Refusing to replace a non-directory app path: " + str(destination))
            backup = output / ("Switch.app.previous-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
            os.rename(destination, backup)
        try:
            os.rename(app, destination)
        except OSError:
            if backup:
                os.rename(backup, destination)
            raise
    print("Built:", destination, flush=True)
    print("Commit:", info["BuildCommit"], "| Architecture:", arch)
    print("Local ad-hoc signature; no Sparkle updater or notarization.")
    if backup:
        print("Previous build:", backup)
    print("Quit the running Switch before installing or opening this app.")


if __name__ == "__main__":
    main()
