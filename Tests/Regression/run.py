#!/usr/bin/env python3
"""Compile the application sources with regression extensions; no Xcode project required."""

import platform
import subprocess
import tempfile
from pathlib import Path


def main():
    tests = Path(__file__).resolve().parent
    repo = tests.parents[1]
    source = repo / "Sources" / "Switch"
    with tempfile.TemporaryDirectory(prefix="switch-regressions-") as directory:
        output = Path(directory)
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
        executable = output / ("SwitchRegressionTests-" + output.name)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5",
            "-target", f"{platform.machine()}-apple-macosx14.0",
            "-import-objc-header", str(source / "Switch-Bridging-Header.h"),
            *swift_sources, str(tests / "RegressionMain.swift"), str(exception_object),
            "-F", "/System/Library/PrivateFrameworks", "-framework", "SkyLight",
            "-o", str(executable),
        ], check=True)
        try:
            subprocess.run([str(executable)], check=True)
        finally:
            subprocess.run(["defaults", "delete", executable.name],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
