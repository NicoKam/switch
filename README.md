# Switch (NicoKam fork)

[简体中文](README.zh-CN.md)

A macOS window switcher based on [Sanyam-G/switch](https://github.com/Sanyam-G/switch), with three-finger trackpad navigation and English / Simplified Chinese localization. **Clone this repository's `main` branch to get both features.**

This is an independently maintained, AI-assisted fork. The upstream maintainer does not merge AI-generated PRs, so our changes are developed and distributed here. It is not an official upstream release. Original development, website and copyright remain credited to Sanyam Garg.

## Changes from upstream

| Feature | What this fork adds |
| --- | --- |
| Three-finger navigation | Swipe horizontally to open the picker, then move left/right/up/down to select a window. Lift your fingers to switch; Esc cancels. |
| Trackpad recovery | Per-device frame monitoring, sleep/wake rediscovery, stale-session cleanup, callback registration isolation and delayed device retirement. Diagnostics help investigate intermittent failures. |
| Picker layout | Optional automatic columns based on display width, plus grid navigation and display-placement fixes. |
| Localization | Follow System, English and Simplified Chinese choices for Settings, menu bar menus and About. Language changes refresh those interfaces without restarting. |
| Source builds | A command-line build script packages translations, app icon and an ad-hoc signature without Xcode project generation or upstream signing credentials. |
| Updates | Updates are manual from this fork's source. The official Sparkle feed is disabled so an upstream binary cannot replace the fork's features. |

The current upstream base is **v0.3.17**, commit [`4cffdf7`](https://github.com/Sanyam-G/switch/commit/4cffdf72f233603663b50e6c0d709e118aacf9bc). `main` integrates the former trackpad and localization feature branches and the subsequent lifecycle fixes.

## Build from source

Requirements: **macOS 14+**, Apple Command Line Tools, Git and Python 3. The build runs on Apple Silicon or Intel and produces an app for the architecture used by the compiler. Full Xcode, Homebrew, XcodeGen, a Developer ID certificate and a Sparkle download are not required for this build path.

Install Apple's tools if they are not already installed:

```sh
xcode-select --install
```

After installation completes:

```sh
git clone --branch main https://github.com/NicoKam/switch.git
cd switch
python3 Tests/Regression/run.py
python3 scripts/build-local.py
```

The app is written to **`build/local/Switch.app`**. The script compiles source, validates and copies both translation catalogs, generates the icon, records the source commit and verifies its ad-hoc signature. Rebuilding preserves any previous app in that output directory with a timestamped name. It does not install or launch the app automatically.

To install, quit any running Switch, then drag `build/local/Switch.app` into Applications. This fork keeps the upstream app name and bundle identifier, so it replaces that installation; run one copy at a time. Grant Accessibility in System Settings. Screen Recording is needed only for thumbnails. As an ad-hoc signed source build, it is not Apple-notarized; use macOS's normal approval flow if prompted. Rebuilding can require reauthorizing permissions.

The upstream Homebrew cask and official DMG contain upstream features, **not this fork's additions**. `scripts/release.sh` is the inherited upstream distribution pipeline and requires the upstream signing/notarization setup; use `build-local.py` for a personal build.

### Ask an AI coding assistant to build it

Give an assistant access to a Mac and this prompt:

> Clone https://github.com/NicoKam/switch.git on main. Read README.md. Confirm macOS 14+, Apple's Command Line Tools and Python 3 are available. Run python3 Tests/Regression/run.py and python3 scripts/build-local.py. Build directly from source with the bundled English and Simplified Chinese resources. Report the test results, source commit, output app path and installation steps. This is the fork with both three-finger navigation and localization.

## Enable the features

- **Three-finger gestures:** Settings → Picker → Behavior → Three-finger swipe. Swipe horizontally to open the picker, navigate in either axis and lift your fingers to select. Disable conflicting macOS three-finger Mission Control / App Exposé or dragging assignments if they interfere.
- **Language:** Settings → Appearance → Language → Follow System, English or 简体中文. The translation scope currently covers Settings, menu bar menus and About; some picker/onboarding text still uses upstream English.
- **Automatic grid columns:** Settings → Picker → Sizing → Automatic columns. Otherwise the configured column count is used.

The original keyboard workflow remains available: ⌘-Tab cycles windows, ⌥-` cycles the current app, Return selects and Esc cancels. The upstream cross-Space, vertical list, exclusion, sticky picker and optional Vim navigation features remain.

## Trackpad diagnostics and limitations

Gestures use Apple's private MultitouchSupport framework. Its raw touch stream can stop silently, especially around sleep/wake; this fork detects and rebuilds registrations rather than claiming to fix the framework itself. Recovery is checked every second, considers a stream stale after roughly 30 seconds, and backs off repeated failed recoveries. Retired device objects intentionally retain a process-lifetime reference to avoid observed framework teardown crashes.

Diagnostics are appended to **`/tmp/switch-gesture.log`**. For a bug report, include the source commit from About, macOS version, trackpad type, reproduction steps and relevant log lines around the failure. Regression tests use a mock MultitouchSupport library; passing tests does not prove the private framework will stay alive on every Mac.

## Updating this fork

For users with an unchanged checkout:

```sh
git switch main
git pull --ff-only origin main
python3 Tests/Regression/run.py
python3 scripts/build-local.py
```

Save any local edits before updating. Quit Switch and install the new build afterward. The app's update link opens this repository's build instructions; it does not download official binaries.

For maintainers, integrate upstream changes into a temporary branch and merge the validated result into this fork's `main`:

```sh
# Add this remote once; skip this line if upstream already exists.
git remote add upstream https://github.com/Sanyam-G/switch.git
git fetch upstream
git switch main
git pull --ff-only origin main
git switch -c sync/upstream-YYYY-MM-DD
git merge upstream/main
# Resolve conflicts while retaining the fork's gestures, translations,
# build script, README and SwitchForkBuild update policy.
python3 Tests/Regression/run.py
python3 scripts/build-local.py
# Also check real gestures, sleep/wake and both languages on a Mac.
git switch main
git merge --ff-only sync/upstream-YYYY-MM-DD
git push origin main
```

Upstream updates are integrated deliberately; this repository does not currently run an automatic synchronization job. Report fork-specific issues [here](https://github.com/NicoKam/switch/issues).

## License and attribution

The original [FSL-1.1-MIT license](LICENSE.md) and copyright notices are retained. This fork's modifications are distributed under that same license. This is a source-available project; do not describe the current license as an unrestricted MIT license.

Original project: [Sanyam-G/switch](https://github.com/Sanyam-G/switch) · [Website](https://switch-dev.sanyamgarg.com) · [Support the original author](https://www.paypal.com/paypalme/sanyamg0).

© 2026 Sanyam Garg. Fork modifications maintained by NicoKam.
