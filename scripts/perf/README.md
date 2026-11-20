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
