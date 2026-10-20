# Executed Linux descendant qualification

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
