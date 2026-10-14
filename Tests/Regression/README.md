Run on macOS with the Swift command line tools:

```sh
python3 Tests/Regression/run.py
```

The runner compiles the application sources with same-file test extensions in a temporary directory, so private state can be exercised without adding production test hooks. It injects synthetic contact frames and window snapshots, uses an unseen panel for layout checks, and never starts native trackpad capture or focuses a real window. Its executable has a unique preferences domain that is removed afterward.

Trackpad lifecycle tests load a standalone mock `MultitouchSupport` dylib built by the runner. They execute the production discovery/register/unregister/rebuild path, verify per-device zero-frame recovery and retry spacing, and inject an old callback waiting for the state lock. A deliberately slow unregister batch verifies the full quiet interval, in-flight callback barrier, and exactly one stop per retired registration. The tests also assert that rediscovery releases actual scroll interception and cancels a pending picker session. No native MultitouchSupport device is opened.

Runtime diagnostics are appended to `/tmp/switch-gesture.log` with a PID, device pointer and registration epoch. Useful records include `registered`, `first frame`, `stale streams`, `session cancelled`, `ignored obsolete frame`, `queued retirement` (including unregister duration), `retirement waiting` (in-flight callback count), `stopping retired` and `stopped retired`. A `stopping retired` without a corresponding `stopped retired` identifies teardown as the last completed operation; `retained` reports the number of intentional process-lifetime device references.

Layout fixtures wait for the expected asynchronous update with a bounded timeout rather than relying on a fixed 30ms scheduling window. Test stdout is unbuffered so completed checks remain visible if a later precondition fails.

Localization fixtures run inside a temporary app bundle containing the real English and Simplified Chinese catalogs. They check persisted language choices, switching back to English, formatted labels, missing-key fallback and the fork's manual-update policy. The bundle identifier uses the same unique name as the executable, keeping test preferences separate from the installed app.
