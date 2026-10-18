# Memory budgets

For a fresh installed toolchain, [prepare and review a profile](prepare-toolchain.md) before running the SDK entrypoints.

MemoryBudget gives Crystal specs and CI one typed contract for limits, measurements, capabilities and verdicts. Crystal owns allocation counters. This package owns policy and verification. Your application owns the operation, useful behavior and memory allowance.

This is the **0.1.1 local documentation candidate**, based on the 0.1.0 API source. Public release, ordinary-device installation and installed-agent qualification remain separate acceptance gates. The source manifest records document/example hashes; the website projection records the actual source checkout commit and its clean/dirty state.

Start with [the working fiber tutorial](fiber-budget.md), then [choose the right measurement](capabilities.md) and [connect it to CI](ci.md). The executable example is part of this versioned corpus. Policies live in app-owned `performance/memory_budget.json`; `shard.yml` stays package metadata.

## Where the examples go

Run the tutorial from the MemoryBudget repository root. In an existing application, extend its spec helper and operation specs while preserving its current setup. Amber's candidate `performance init --kind=web|native` installs a kit into an app without colliding kit files. The generated native starter policy covers process-manager logic; complete native window/process journeys have their own policy and platform acceptance.

## What acceptance means

Use a real functional assertion beside the memory expectation. Measure the normal operation and prove that an actual added allocation or a tightened limit fails. Keep its raw evidence, scope, counter protocol, source and dependency identities, executable hash, compiler profile and policy hash. Missing required evidence is failed acceptance.

The dedicated memory command enables the admitted allocation protocol. Ordinary uninstrumented specs may explicitly delegate a pending memory example to that required job. A configured workflow, a locally executed job, a remote required-check result, a public release and an installed consumer each have their own evidence.

## For agents

The repository skill is `skills/crystal-memory-budgets/SKILL.md`. It teaches the operation/owner/window decision and exact evidence boundaries. It links the matching corpus rather than independently redefining the API. Skill installation/discovery and useful independent agent tasks are qualification steps; the presence of a skill folder alone establishes source packaging.

For applications with native dependencies, use the [native toolchain guide](native-toolchain.md) to admit exact library files and qualify ordinary Ruby entrypoints.

For frozen dependency installation and CI source identity, use the [Git provider guide](git-provider.md). The full workflow requires toolchain profile schema 3; compiler-only legacy profiles retain their narrower scope.
