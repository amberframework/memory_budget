# Memory Budget

Memory Budget gives Crystal specs and CI one typed enforcement contract. Crystal owns allocation counters; this shard owns limits, measurement adapters, validation, and verdicts. Amber connects those measurements to routes, jobs, models, and native journeys.

This is the implementation candidate for the memory-budget-experiment. Publication and supported-platform receipts are tracked separately from local implementation.

## Run the examples

The checked-in toolchain profiles identify approved compiler binaries and standard-library trees by SHA-256. `scripts/budget.rb` resolves the installed `crystal-alpha` wrapper, verifies its backend and stdlib, verifies the four runtime overlay files, and runs the compiler with the counter-enabled stdlib. Every file in the prepared stdlib is checked. A different compiler needs a reviewed profile.

The 0.1.1 bootstrap selects a profile by the complete compiler, standard-library,
and actual Ruby executable identity. A declared compiler-wrapper or Ruby-launcher
hash participates in admission. Multiple profiles may share a compiler backend;
the matching Ruby and stdlib select the supported combination. More than one
complete match requires explicit selection. An explicit profile remains an exact
choice, and a mismatch produces a named refusal.

```sh
ruby scripts/toolchain_profile.rb --json
MEMORY_BUDGET_TOOLCHAIN_LOCK=/reviewed/toolchain.json ruby scripts/budget.rb --version
```

The first command prints the admitted paths, hashes, profile, and counter protocol
without compiling. Discovery finds `crystal-alpha` through `PATH`, or uses the
explicit `MEMORY_BUDGET_COMPILER` path. Static wrappers use an absolute `exec`
backend followed by `"$@"`; quoted and shell-escaped spaces are supported. The
bootstrap reads this wrapper as data and invokes its pinned backend directly.
An installation with a changed wrapper needs its reviewed wrapper hash. A
direct-backend profile can omit `wrapper_sha256`; a profile that declares that
hash requires the matching entrypoint. `MEMORY_BUDGET_STDLIB` names an explicit
installed standard-library root when automatic discovery is unsuitable.

Each profile requires schema1, a nonblank `profile`, counter protocol1, and
`compiler_sha256`, `stdlib_sha256`, and `ruby_sha256`. Optional
`ruby_launcher_sha256` is enforced when present. A script compiler entrypoint
requires its own `wrapper_sha256`; a direct native backend uses its exact
`compiler_sha256` and can omit the wrapper field.
The Ruby launcher is located through `PATH` or
`MEMORY_BUDGET_RUBY_LAUNCHER`; the actual running Ruby is always independently
checked through `RbConfig.ruby`. `MEMORY_BUDGET_TOOLCHAIN_PROFILE_SHA256` binds an
explicit profile's bytes during a consumer run. Profiles are reviewed tool
configuration, separate from app settings and package metadata.

```sh
ruby scripts/budget.rb
ruby scripts/budget.rb run examples/fiber_and_items.cr -Dfiber_allocation_tally
ruby scripts/budget.rb run examples/process_memory.cr -- 67108864
ruby scripts/budget.rb run examples/process_memory.cr -- 1024
ruby scripts/budget.rb run examples/c_allocation_owner.cr -- 1680
ruby scripts/budget.rb run examples/c_allocation_owner.cr -- 1679
ruby scripts/budget.rb run examples/joined_process.cr -Dfiber_allocation_tally -- 65536
ruby scripts/budget.rb run examples/joined_process.cr -Dfiber_allocation_tally -- 1
ruby scripts/budget.rb run examples/sqlite_cache.cr -- 1048576
ruby scripts/budget.rb run examples/sqlite_cache.cr -- 1
```

The first process and C-owner commands pass; their tight-limit counterparts exit 2. The C example replays hash-pinned research evidence, while the process example measures its own live touched 8 MiB buffer. The SQLite specification opens a real connection, grows its cache with 100 blobs, and checks sufficient and tight limits. Instrumented spec runs require the runtime capability explicitly.

The SQLite adapter supplies its own SQLite link by default. A caller whose driver
already owns that link compiles with `-Dmemory_budget_sqlite_linked_by_caller`.
This gives the final executable one link owner while preserving the live
connection-status API. Grant's runnable SQLite example exercises that integration.

## Use it in a spec

Require `memory_budget/spec_expectations` from the existing spec helper. For the embedded distribution, require `../performance/vendor/memory_budget/src/memory_budget/spec_expectations` instead. App-owned memory policies stay in `performance/memory_budget.json` or the typed configuration API, with package metadata in `shard.yml`. Existing latency policies retain `performance/budget.json`.

```crystal
within_allocation_budget("render_summary", calls: 4, bytes: 256) do
  render_summary
end

within_process_allocation_budget("joined_import", calls: 200, bytes: 16_384) do
  import_records_and_join_workers
end
```

The example operation names describe application-owned methods. The runnable programs and specs supply complete working examples. Use `within_memory_budget` with a typed `ScenarioMemoryPolicy`, or select a policy by scenario from `ScenarioMemoryContract`. Fixed-plus-per-item policies use checked arithmetic and exercise explicitly declared input sizes. Construct the inputs and policy before the measurement window.

## Where each measurement belongs

| Check | Implementation layer | Intended use and limit |
| --- | --- | --- |
| Per-fiber calls/requested bytes | Crystal GC/fiber hooks | Deterministic allocation specs for synchronous model, renderer, parser, or request work |
| Joined-process allocation traffic | Crystal process tally | An isolated operation that joins workers; every allocation in that process window counts |
| Fixed plus per item | Shared policy checker | Check declared cardinalities; the same rule applies to calls or bytes |
| C calls/requested bytes | Validated C instrument plus typed adapter | All required windows and zero loss counters; cold startup and warm library work have distinct scopes |
| C allocation-owned live bytes | Allocation-owner map | Count releases against their allocating source even when an optimized free loses a Crystal frame |
| SQLite cache bytes | SQLite connection-status API | Bound a real connection's cache; a successful global zero does not prove an empty cache |
| Process footprint/peak | Public OS counters | Whole web/native app checkpoints and fresh-process lifetime peaks |
| Compiler RSS | Supervisor and compile roster in the library integration | Keep semantic/codegen/LLVM phases and model counts separate from runtime allocation limits |

Darwin physical footprint and Linux resident memory have separate metric names. Peak means lifetime peak, and a fresh process provides an independent scenario. A checkpoint reading establishes its checkpoint value. The metric family makes that boundary explicit.

Requested allocation bytes, live C blocks, collector reservation, and physical pages overlap. Compare each with its own limit. Freed blocks can remain resident in an allocator's retained pages.

## One fail-closed contract

Every scenario declares its exact metric roster and scope. The checker validates nonempty policies, unique required scenarios, complete observations, matching scopes/platforms/backend revisions, and checked limits. Missing counters, incomplete C maps, unsupported required capabilities, unknown policy and evidence JSON fields, omitted readings, and exceeded limits fail acceptance. Zero is a valid explicit limit.

The command reads a typed contract and evidence receipt and writes a report:

```sh
memory-budget check performance/memory_budget.json performance/evidence.json performance/report.json
```

Exit 0 requires every declared scenario to have an enforced pass. Exit 2 identifies a failed acceptance. The receipt names source commit, executable SHA-256, policy SHA-256, compiler identity, instrumentation mode, capabilities, and observations. Raw measurements and the report belong in CI artifacts, including failed runs.

## Research boundaries carried into the implementation

The original C experiment retains six SQLite cold-scope comparison failures and three optimized free-source failures. The supported checks use broad process/C cold budgets, connection cache counters, and allocation-owned releases. An exact optimized free call site remains outside the declared capability. Nested-hook live-map loss is a rejection fixture. A reporting program's successful exit alone establishes process completion; the verdict and required roster establish acceptance.

Runtime counters are compiled with `-Dfiber_allocation_tally`. Ordinary release process-memory runs can omit them. Instrumentation mode and compiler profile travel with the evidence, and timing/footprint thresholds use the corresponding build profile.

## Distribution

The shard has no runtime dependencies. Its embedded distribution carries one identical source bundle, a per-file SHA-256 manifest, the four maintained-runtime overlay files, and a versioned counter protocol. This lets an Amber application or library use the same code before a public shard release exists. Generated wrappers verify that manifest before invoking it. A standalone shard release can use the same public entry points.

The runtime overlay is derived from Crystal Alpha commit `9c1e8ec64f6be6343e90d3979bc9536c4b050292`; its Crystal source license is preserved in `LICENSE-RUNTIME`. Application thresholds remain product decisions based on measured workloads and admitted platform profiles.

The included CI template uses `memory-budgets / darwin-arm64-v1` on a controlled
runner labeled `atlas-memory-budget-v1`. Its preflight verifies the approved
backend, Ruby executable, entire standard library, and shared bundle by hash.
Runner admission and required-check configuration are deployment steps. The
same script executes locally; a workflow file alone is not an executed CI result.

The CI job installs dependencies from a committed checksum-bearing lock using the
verified Minecart executable before running specs. Commit the generated app's
lock after its initial strict install. The isolated Crystal stdlib gate requires
its checkout sources and compiler profile; compiler-shard dependencies belong to
the compiler's separate build workflow.

The dependency step uses the same admitted compiler profile and resolves
`minecart` through `PATH`, with an optional explicit `MEMORY_BUDGET_MINECART`
path. That profile supplies exact `minecart_sha256` and `minecart_version`
values. The tool hash is verified before its version or install command runs.
The installer retains frozen checksum coverage, one worker, and unchanged
manifest/lock checks. It records the resolved toolchain and dependency identities
in `performance/results/dependency-toolchain.json`. The consumer wrapper also
selects the admitted profile rather than fixing its filename to Darwin.

```sh
ruby performance/vendor/memory_budget/scripts/install_frozen_dependencies.rb
ruby performance/run_memory_budgets.rb --self-test
```

The workflow still declares its controlled Darwin ARM64 runner and calibrated
workload. Portable path discovery supplies reviewed prefixes, including spaces;
it establishes no additional OS, public installation, or second-device support.
The checked-in profile admits the recorded Darwin Alpha/Ruby/Minecart bytes.
Each Linux or other Ruby/compiler combination needs an exact reviewed profile,
its own workload calibration, and executed installation/consumer receipts.
The separate public Homebrew/archive and actual-device qualification remains a
release acceptance stage.

Ruby entrypoint and neighboring contract controls run with the built-in test
library:

```sh
ruby test/portable_toolchain_test.rb
```

They exercise the actual bootstrap and workflow dependency step with identified
fixture executables. These controls verify path and refusal behavior; actual
Crystal counter specs and installed consumers supply compiler/runtime evidence.

The spec/CI wrapper compiles one named spec executable and runs that same file
for its normal and injected-regression controls. It then sends raw measurements
and capabilities to the common typed checker. The emitted verdict label is
supplemental information; the checker independently compares every value.
Reports bind the executable, checker, toolchain profile, policy, source files,
and installed dependency files by SHA-256. A changed source, dependency, policy,
or executable during the run fails acceptance.
