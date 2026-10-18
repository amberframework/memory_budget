# A working fiber allocation expectation

One record construction is a useful small starting operation. This tutorial keeps the record in an existing preallocated collection, checks its value, and measures only construction/append. The sample model and helper are the same source-verified public API used by the package examples.

This page belongs to the 0.1.1 local candidate. Its execution receipt records which compiler/profile and example bytes actually ran; ordinary public installations and independent installed-agent tasks retain their separate gates.

## Where the examples go

**File: `docs/0.1.1/examples/fiber_budget_spec.cr` in the MemoryBudget repository.** This is a complete executable spec. It requires the package's existing `spec_expectations` and `MemoryBudgetSampleRecord` support. Read the complete source alongside this guide; its hash is in the corpus manifest.

The spec creates policy/input state before the window, constructs one record inside `within_memory_budget`, and asserts the resulting record number after the window. A retained extra buffer is created inside the same window only for the regression control. Limits are one call and the actual record instance size. Requested bytes describe this allocation operation rather than physical process pages.

## Build once, exercise both outcomes

**Run from: the MemoryBudget repository root, using its admitted toolchain profile.** Choose a private output directory and keep the source checkout unchanged during the run.

```sh
mkdir -p /tmp/memory-budget-tutorial
CRYSTAL_WORKERS=1 CRYSTAL_CACHE_DIR=/tmp/memory-budget-tutorial/cache \
  /usr/bin/ruby scripts/budget.rb build docs/0.1.1/examples/fiber_budget_spec.cr \
  -Dfiber_allocation_tally -o /tmp/memory-budget-tutorial/fiber-budget-example
/tmp/memory-budget-tutorial/fiber-budget-example
MEMORY_BUDGET_INJECT_REGRESSION=1 /tmp/memory-budget-tutorial/fiber-budget-example
```

The normal run must report one example, zero failures/errors and exit 0. The same identified executable's regression run must fail the memory expectation and exit 1. The extra buffer is a real allocation, and both outcomes retain the same useful record behavior. Record actual compiler color, observed calls/bytes and executable hash from the run; a source snippet alone establishes an intended example.

The SDK bootstrap verifies compiler/standard-library/runtime-overlay identities before compilation. A different supported installation path uses the matching admitted profile. A missing capability fails rather than silently measuring zero. Production timing/footprint budgets use their own ordinary build profile.

## Move the idea into an app

Choose one actual operation and its output assertion. Construct fixtures and the policy outside the measured window. Extend the existing helper with `memory_budget/spec_expectations` or the embedded kit's corresponding relative entrypoint. Collect representative cold/warm repetitions before selecting the app allowance. Keep the policy in the app-owned memory contract and require the dedicated CI job described in [CI guidance](ci.md).

For worker handoff, choose a joined-process window and finish its workers inside the block. For growth, exercise a nonempty explicit list of input counts with fixed-plus-per-item limits. A record micro-example starts the workflow; your app's real operation and its regression supply adoption acceptance.
