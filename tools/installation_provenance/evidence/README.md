# Executed Linux control evidence

The October 20 bundle records
[run 39435844814](https://github.com/amberframework/memory_budget/actions/runs/39435844814)
at source `98ce154b71f6896eff941d8662a9288e08eddc5a`. The ZIP is the original
42-file GitHub artifact, verified against its published SHA256
`4562b5d0e1398f63a725bde4b180ce148101ed3846cf8b1ccecb04346389a0a3`.
The adjacent JSON summarizes the executed scopes and remaining gates.

Both ordinary and optimized Python ran 58 cases with zero failures, errors,
skips, expected failures, or unexpected successes. Nine runner admission
cases passed. A separate admitted 128 MiB allocation probe was killed in its
64 MiB container with exit 137 and the actual Docker OOM marker. An uncapped
container refused with exit 2 before loading its tests. All five owned
containers, including the independent terminal reader, were removed and
read back absent.

The archive includes the source-bound inner results, Docker image and
container inspections, actual exits, test logs, and cleanup records. Extract
a hash-verified copy into a private review directory. The four case results
and `TERMINAL_ACCEPTANCE.json` are under
`memory_budget/memory_budget/tools/installation_provenance/ci-evidence-39435844814-1/`.
The hosted runner identity is under `_temp/atlas-linux-runner.json`.

For a replay with a verified Python runtime and this exact source, run the
existing `verify_terminal.py` with `--evidence` pointing to that extracted
case directory and `--pins-sha256`
`15e27eea749e5d08f7d41256515b078f256c89fed5c49647c09dc99b99406eae`.
It rechecks the source roster, numerical budgets, complete cohorts, image,
commands and terminal states. The cleanup records separately identify each
removed container. Replaying recorded evidence retains its original run
identity; a fresh kernel qualification creates its own workload and results.

These are control-suite measurements, with charged cgroup peaks through
their final snapshots. Compiler RSS, complete-build descendant coverage,
shared-page ownership, ordinary SDK/compiler installation, and clean-device
acceptance remain required. Grant's final 300/500-model matrix remains 0/144.
