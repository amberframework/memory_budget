---
name: crystal-memory-budgets
description: Add, calibrate, and diagnose memory expectations in Crystal and Amber specs and CI using the versioned MemoryBudget contract.
metadata:
  version: "0.1.1"
  distribution: "public-review-candidate"
  repository-state: "public-source-verified"
  revision: "draft-4"
---

# Crystal memory budgets

Turn one concrete operation and its memory limit into a useful executable expectation, then prove normal behavior and an actual over-budget failure.

Read the matching source corpus at `docs/0.1.1/` in the SDK checkout, or the version/source-attributed Amber memory-budget pages supplied by the docs tools. The manifest identifies the exact API/example bytes. Public review source is available in [amberframework/memory_budget](https://github.com/amberframework/memory_budget). Select the consumer's exact release or reviewed commit and verify its manifests. Supported releases, each installed platform/profile, and independent installed-agent qualification have separate acceptance receipts.

For package installation or a fresh-device rollout, read [installation validation](references/installation-validation.md) before selecting the acceptance workload.

Inspect the project's installed toolchain/profile, existing kit, spec helper, policy, hooks and dependency lock. Preserve the app's current setup. Choose the owner/window: synchronous fiber traffic, a joined process operation, a live SQLite connection cache, a whole-process lifetime metric, or an exact compiler/build workload.

For a consumer with native libraries, read `docs/0.1.1/native-toolchain.md`. Use a schema-2 toolchain profile with its required native manifest hash and explicit lock. Frozen dependency installation additionally uses the schema-3 Git provider described in `docs/0.1.1/git-provider.md`. Preserve the admitted original wrapper when the SDK delegates to its backend. Verify the actual emitted and loaded library closure, then the ordinary SDK/app Ruby entrypoints; those are separate from static file/path admission. Review new native bytes, links, search order or diagnostic loader tracing as a new manifest/profile identity. A schema-1 installed SDK example retains its narrower compiler/spec/tutorial scope.

Use a real functional assertion. Construct inputs and policy outside the measurement window. Keep app policies in `performance/memory_budget.json`; keep package metadata in `shard.yml`. Calibrate repeated cold/warm behavior and explicit nonempty input counts.

Read the installed Amber command help before choosing a CLI path. Candidate builds with these commands offer `amber performance init --kind=web|native` for apps without kit collisions and `amber performance check --self-test` for the installed kit. Use the versioned SDK bundle entrypoints for other supported installations. Native starter logic and complete native user journeys have distinct scopes.

Run the same named program normally and with a real allocation regression or tight limit. Require raw typed evidence, complete scenario/metric/capability rosters, source/dependency/policy/executable hashes and admitted counter protocol. Independently verify numerical limits. Missing evidence is failed acceptance.

Report observed/allowed values, scope/profile, repetition count, functional result and exact rejection. A workflow file, local execution, remote required check, public release and installed consumer each retain their own status. Grant's strict 300/500-model complete-build target remains unmet until its full RSS/whole-build matrix and compatibility gates pass.
