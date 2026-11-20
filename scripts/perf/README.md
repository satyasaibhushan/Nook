# Reading UI benchmark results

`uibench.py` writes JSON and a Markdown summary. The launch metric measures
the time from launch start to the first post-launch frame that matches at
least 97% of the settled window. The CLI scenario is still `--only cold`, and
the JSON keeps `browsers.<browser>.cold_launch.first_full_window_ms`. Each
launch result includes a label describing its profile and cache conditions.

Nook's launch trials start a fresh process with a warm filesystem cache and
shared SwiftData history. The runner leaves the OS filesystem cache in place
and reuses history already on disk for the benchmark bundle ID.

The JSON `isolation_manifest` lists the storage policy for the selected
browsers. Nook redirects tab state to a temporary directory. Its SwiftData
store and user defaults persist across runs of `com.gstudios.nook.perf`.
WebKit website data uses persistent profile IDs, and the favicon disk cache
is shared across Nook bundle IDs. Chrome and Zen use temporary profiles. Arc
uses its persistent profile, and its launch timing requires
`--allow-arc-quit`.

## Running the phases

The default run checks the desktop, captures evidence, then runs offline Vision
recognition. Use the same JSON destination for separate runs.

```sh
scripts/perf/uibench.py --phase preflight --out measurements.json
scripts/perf/uibench.py --phase capture --out measurements.json
scripts/perf/uibench.py --phase analyze --out measurements.json
```

Preflight reports to `measurements-preflight.json`. Capture requires 3 GiB free
on each volume it uses by default. The release build requires 10 GiB. The
desktop lock is shared across worktrees, and the load1 limit defaults to 4.

`--ax-mode inspected` normalizes window size and uses Accessibility controls.
`--ax-mode none` keeps the browser's window geometry and skips trials that
need AX controls. Arc is skipped in this mode because its shared tabs require
AX ownership checks. Both modes still need Screen Recording and synthetic
input permission.

Copy the JSON and its sibling `measurements-evidence` directory to run analysis
offline elsewhere. The report keeps browser input validation and OCR status
independent. `--ocr-timeout` bounds each Vision invocation and `--ocr-budget`
bounds recognition across the batch.
