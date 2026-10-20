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
ten fresh containers, checks commands, kernel limits, functional page counts,
membership and terminal results, then removes only its exact owned identities
and reads them back absent. All measurements and cleanup records become CI
artifacts. Missing or inconsistent evidence fails acceptance.

Sixteen sensitivity controls change copies of the actual observations across
both execution modes. They challenge retained peaks, process birth and
adoption, orphan membership, sibling charges and hierarchy, kernel counters,
and executed commands. Every changed copy must fail; the restored actual
dataset must pass. Original observations remain available in the artifact.

These are synthetic private-allocation and process-boundary controls. Their
actual execution and raw verification determine which claims are earned.
Shared/migrated-page ownership, compiler-process RSS, a complete real build,
ordinary installation, and Grant's 300/500-model matrix retain their separate
required evidence. See the [kernel cgroup documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html).
