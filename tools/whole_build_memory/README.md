# Whole-build process-boundary qualification

This source candidate extends the accepted Linux installation-control gate.
The existing seven-file provider and 58-case cohorts retain their identities.
The new probes test three child lifetimes and a concurrent private sibling
allocation in fresh capped containers, in ordinary and optimized Python.

Each direct child touches 64 MiB of private pages. The parent samples entry
and final state, joins the process, and requires the kernel peak to retain the
allocation after current memory falls. The fork/exec case additionally binds
the PID and kernel start time across exec. The detached case creates a new
session, lets its launcher exit, then requires the supervisor to observe,
adopt, release, and reap the remaining worker before ending the window.

The sibling observer and load overlap. The load touches 192 MiB while the
observer remains below 96 MiB. Read-only host metadata binds the actual Docker
identities and process start times to distinct sibling cgroup paths. The
inner cgroup identity must agree with that host context.

The host driver verifies exact tool/source/profile identities, executes the
sixteen fresh containers, checks commands, kernel limits, functional page counts,
membership and terminal results, then removes only its exact owned identities
and reads them back absent. All measurements and cleanup records become CI
artifacts. Missing or inconsistent evidence fails acceptance.

Fifty sensitivity controls change copies of the actual observations across
both execution modes. They challenge retained peaks, process birth and
adoption, orphan membership, sibling charges and hierarchy, kernel counters,
executed commands, complete parent membership, and window boundaries. Every changed copy must fail; the restored actual
dataset must pass. Original observations remain available in the artifact.

RSS counters have a separate scope and unit. Each process records its own
maximum RSS and the maximum RSS among its waited children in Linux KiB.
Two additional overlapping-worker cases each hold two consumed 64-MiB private
allocations simultaneously. Their whole-group charge must cover both while
the waited-child maximum remains the largest individual worker. Every child
is joined before the final measurement. Damaged-unit, summed-RSS, lost-peak,
typed-counter and missing-live-worker controls challenge these boundaries.
The actual compiler has its own remaining acceptance; this synthetic protocol
supplies a tested measurement boundary.

The shared-page pair adds a 96-MiB file first touched by its writer. Both
consumers verify the full content signature and physical inode and touch
every page through a live mapping. The observer's RSS must rise while its
own cgroup charge stays below 48 MiB; the writer must retain at least 96 MiB
of charge while the observer is live. Independent host metadata binds both
siblings and the same complete file. The driver rehashes and removes the
two owned temporary data files after all containers return, and retains
their identities and absent readbacks in the artifact. Each root probe also
requires a refused write handle to the read-only cgroup control file.
Actual process migration retains a separate acceptance requirement.

These are synthetic private-allocation and process-boundary controls. Their
actual execution and raw verification determine which claims are earned.
Actual process migration, other shared cache/reclaim behavior, compiler-process RSS, a complete real build,
ordinary installation, and Grant's 300/500-model matrix retain their separate
required evidence. See the [kernel cgroup documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html).
