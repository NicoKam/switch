Run on macOS with the Swift command line tools:

```sh
python3 Tests/Regression/run.py
```

The runner compiles the application sources with same-file test extensions in a temporary directory, so private state can be exercised without adding production test hooks. It injects synthetic contact frames and window snapshots, uses an unseen panel for layout checks, and never starts native trackpad capture or focuses a real window. Its executable has a unique preferences domain that is removed afterward.
