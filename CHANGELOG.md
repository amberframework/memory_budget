# Changelog

## Unreleased

### Changed

- The runtime overlay (`runtime_overlay/gc/boehm.cr`, `fiber.cr` and
  `crystal/system/thread.cr`) moves to Crystal 1.22.3. Each file is the
  `crimson-knight/crystal` `v1.22.3-incremental-1` source (commit
  `8ccce497524ef3e35fdc48c487854ab0743b0541`) with memory_budget's allocation
  tally hooks applied unchanged: the `GC.malloc`, `GC.malloc_atomic` and
  `GC.realloc` records, the fiber live-list and thread-start hooks, and the
  `Thread#current_fiber=` switch-out hook. Crystal 1.22.3 calls `GC.syscall`
  from `crystal/system/unix/pthread_condition_variable.cr`, which the 1.21
  overlay's `gc/boehm.cr` did not define, so specs built against an installed
  1.22.3 standard library stopped with `undefined method 'syscall' for
  GC:Module`.
- The overlay now requires Crystal 1.22.3 or newer and stops at compile time
  with a message naming the compiler version when an older compiler reads it.
  Use commit `58c20acfed71e27cbcf207014f29d7c7b53dab18` with Crystal 1.21.
  `shard.yml` declares `crystal: ">= 1.22.3, < 2.0.0"`.
- `toolchain.darwin-arm64.json` still names the Crystal 1.21 build it was
  measured on (`9c1e8ec`). Prepare a profile for an installed 1.22.3 compiler
  with the [profile-preparation CLI](docs/0.1.1/prepare-toolchain.md) before
  running `scripts/budget.rb` on darwin-arm64.
