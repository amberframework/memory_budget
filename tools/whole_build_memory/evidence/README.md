# Executed Linux descendant qualification

## RSS protocol extension

Source `3ea3bfcc55e1e520ee25d69000ea5e8d17d4a62a` adds self and
largest-waited-child RSS counters, with Linux KiB units, to every observation.
The new source manifest is
`a2b816772ffc66ed8bebbb405c52f54434baa663a5d6afae63e87252da1b287c`.
The original seven-file provider is unchanged. Two further cases hold two
consumed 64-MiB private allocations live at once. In the ordinary case,
the largest waited-child RSS peak is 94,117,888 bytes and the whole-group
charged peak is 185,487,360 bytes. This demonstrates why the two metrics
need their own names and budgets. Linux documents the largest-child scope
in [getrusage](https://man7.org/linux/man-pages/man2/getrusage.2.html).

[Actual run 39449551836, attempt 2](https://github.com/amberframework/memory_budget/actions/runs/39449551836/attempts/2)
passes twelve probes, 34 changed-actual-result controls, the preserved
58-case cohorts and nine profile controls, real OOM and uncapped refusal,
and complete return of all seventeen containers. Independent replay binds
all 162 raw files. Archive `linux-rss-39449551836-attempt-2.zip` is
169,372 bytes, SHA256
`4ff7637e68a81fa5ed218733a14238219b9b9908a23cdddc4a836136da7999cf`.
The acceptance and GitHub metadata files are retained beside it. Replay
uses that source commit, its exact manifest, token `39449551836-2`, and the
directory containing `HOST_RESULT.json`. The same validation entry points
described below apply.

The original attempt is also retained. Its ordinary/optimized controls
passed, but the deliberately over-limit process exited 137 with Docker's
OOM marker false. The existing predicate refused before the RSS stage.
All five containers were removed and read back absent. One controlled
repeat retained the same source and exact OOM predicate; the complete
observed tool/kernel/runner profiles match between attempts. A successful
repeat preserves the first attempt's evidence. The missing marker's cause
and its effect on operational reliability remain open release questions.

The first archive is 49,299 bytes, SHA256
`e3600ec03e73ffb8eaeec868628fd70b85ec38e610bf9420b36e0fc5b850843f`,
with its complete 41-file roster and five returns in the refusal JSON.
The repeat decision is also retained. The gate continues to require the
actual OOM marker; exit 137 alone earns no OOM acceptance.

This extension qualifies synthetic self/largest-child RSS observations.
The actual compiler, shared/migrated charges, whole real builds, normal
installation and devices remain required. Grant remains **0/144**.

## Earlier descendant and sibling dataset

Source `b2da5a87af39cbb198d315512d60a4f7e7fc0431` passed the
[actual hosted run](https://github.com/amberframework/memory_budget/actions/runs/39447776437).
Its exact three-file source manifest is
`061ece6c4c78bd2e1c471facfcc048d81db09065f5935e3cda925a07bcfb8f09`.
The original seven-file provider manifest remains
`15e27eea749e5d08f7d41256515b078f256c89fed5c49647c09dc99b99406eae`.

The accepted archive `linux-descendants-39447776437.zip` is 146,765 bytes,
SHA256 `5bbdcbb53413e7f95fb67f310802a925cb767d2b06ea451dc409704fae059b4d`.
That digest matches GitHub's artifact metadata retained beside it. Its 140 raw
files include runner identity, ten actual probes, both preserved 58-case
cohorts, kernel OOM and uncapped controls, full terminal inspections, and all
fifteen owned-container removal and absent readbacks. The acceptance JSON
lists every raw path, length, and SHA256.

The ten probes cover direct children, fork/exec children, detached children,
and simultaneous sibling observer/load processes, each in ordinary and
optimized Python. All three child paths touch 64 MiB. Their final kernel
peaks retain the retired charge after the supervisor rejoins every worker.
The separate sibling load touches 192 MiB while the observer remains below
96 MiB; host Docker/PID/cgroup identities bind the two separate siblings.
Twenty-four changed copies of actual observations are rejected, and the
restored actual dataset passes. Independent replay also verifies every
terminal result and cleanup record.

## The reader defect that the first green run missed

The earlier source `568aee6a60f380612f13c29aa2610ddc7c90aaf3` passed its
[ten actual workloads and sixteen original damage controls](https://github.com/amberframework/memory_budget/actions/runs/39447337794).
Its complete initial archive is retained as
`linux-descendants-39447337794-initial.zip`, 146,576 bytes,
SHA256 `0cf4bd1a5db3c72ed5fee971e8c5734efa0504500aa5ce8abe90de67d696a5c9`.
Independent review removed parent/launcher PIDs from the hot worker records;
the old validator accepted all six changed cases. The audit JSON preserves
those observations. The corrected reader requires every live parent and
worker, and binds entry/allocation/adoption observations to the complete
window. Fresh execution and 24 damage controls qualify that correction.

## Replaying the results

Verify the archive digest against the retained GitHub metadata and use the
exact source commit above. Extract the complete archive into a private
directory, preserving its paths. The two entry points in
`tools/whole_build_memory/verify_results.py` are
`validate(evidence_directory, source_manifest_sha256, run_token)` and
`sensitivity_controls(evidence_directory, source_manifest_sha256, run_token)`.
Use the descendant directory containing `HOST_RESULT.json`, the source
manifest above, and run token `39447776437-1`. Both functions read the actual
dataset and verify the complete source roster before accepting it. Compare
their complete results with `HOST_RESULT.json`; then verify each owner in
its cleanup-before, removal, and cleanup-after files. Docker's `Mounts`
array may arrive in different orders; compare its complete unique records
by destination while preserving every field.

The exact runtime image and host tool/profile hashes are retained in the
raw metadata. The runtime image is
`python:3.12.10-slim@sha256:fd95fa221297a88e1cf49c55ec1828edd7c5a428187e67b5d1805692d11588db`.
The complete fresh execution remains in
`.github/workflows/linux-kernel-budget-controls.yml`.

## Acceptance boundary

This dataset qualifies private-allocation descendant peak retention,
recorded membership and window boundaries, sibling isolation, and terminal
return on the admitted Linux profile. The reported peak is cgroup-charged
memory. Shared/migrated-page charge behavior, compiler-process RSS,
complete real builds, ordinary SDK installation and clean devices retain
their separate required evidence. Accepted Grant target cells remain **0/144**.
