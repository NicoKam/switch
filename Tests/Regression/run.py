#!/usr/bin/env python3
"""Compile the application sources with regression extensions; no Xcode project required."""

import os
import platform
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    tests = Path(__file__).resolve().parent
    repo = tests.parents[1]
    source = repo / "Sources" / "Switch"
    with tempfile.TemporaryDirectory(prefix="switch-regressions-") as directory:
        output = Path(directory)
        mock_library = output / "FakeMultitouchSupport.dylib"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-emit-library",
            str(tests / "FakeMultitouchSupport.swift"), "-o", str(mock_library),
        ], check=True)
        swift_sources = []
        for original in sorted(source.glob("*.swift")):
            if original.name == "SwitchApp.swift":
                continue
            fixture = tests / f"{original.stem}Tests.swift"
            contents = original.read_text()
            if fixture.exists():
                # Same-file extensions can exercise private state without adding production test hooks.
                contents += "\n" + fixture.read_text()
            copied = output / original.name
            copied.write_text(contents)
            swift_sources.append(str(copied))
        exception_object = output / "ObjCException.o"
        subprocess.run([
            "xcrun", "clang", "-c", "-fobjc-arc", "-mmacosx-version-min=14.0",
            str(source / "ObjCException.m"), "-o", str(exception_object),
        ], check=True)
        executable_name = "SwitchRegressionTests-" + output.name
        app = output / (executable_name + ".app")
        executable = app / "Contents" / "MacOS" / executable_name
        executable.parent.mkdir(parents=True)
        resources = app / "Contents" / "Resources"
        resources.mkdir()
        for language in ("en", "zh-Hans"):
            shutil.copytree(source / "Resources" / (language + ".lproj"), resources / (language + ".lproj"))
        with (app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump({
                "CFBundleIdentifier": executable_name,
                "CFBundleExecutable": executable_name,
                "CFBundlePackageType": "APPL",
                "CFBundleDevelopmentRegion": "en",
                "CFBundleLocalizations": ["en", "zh-Hans"],
                "SwitchForkBuild": True,
                "LSUIElement": True,
            }, handle)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5",
            "-target", f"{platform.machine()}-apple-macosx14.0",
            "-import-objc-header", str(source / "Switch-Bridging-Header.h"),
            *swift_sources, str(tests / "RegressionMain.swift"), str(exception_object),
            "-F", "/System/Library/PrivateFrameworks", "-framework", "SkyLight",
            "-o", str(executable),
        ], check=True)
        try:
            subprocess.run([str(executable)], check=True, env={
                **os.environ, "SWITCH_REGRESSION_MT_LIBRARY": str(mock_library),
            })
        finally:
            subprocess.run(["defaults", "delete", executable.name],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
