# Validate the installed budget tooling

Use the exact released docs and checksum-bearing source/toolchain manifests selected by the consumer. Record a draft source identity as a draft. Read the actual installed command help and the project package entrypoint before choosing the workload.

Treat these as separate acceptance results:

1. **Dependency resolution.** Run the supported writer and frozen installer with the consumer's constraints. Retain the generated root lock, source checksums, installed membership, and package/script ordering. Inspect any nested lock the build creates. Existing DB 0.14 and DB 0.15 compatibility results retain their own exact closures.
2. **Executable construction.** Locate the declared target, postinstall behavior, and installed executable. If a CLI conditionally includes database adapters at compile time, prove the requested adapter is available when that compilation occurs. A consumer build after dependency installation and an executable package with explicit adapter dependencies are distinct supported designs; select the design the library actually implements.
3. **Installed behavior.** Run the produced executable from its installed location with an owned fresh HOME and cache. Exercise the intended operation against a dedicated test database and assert actual schema/data/history, along with the command result. Record the executable hash and its actual tool invocations. A linked program also needs a successful loader/runtime check; on a failed Linux load, retain the generated ELF after its writers retire and inspect its actual dependency/search metadata.
4. **Budget behavior.** Run the named operation with its functional assertions and full metric/scenario coverage. Exercise a real over-budget neighbor and restore the passing workload. Retain raw evidence, limits, metric names, scope, platform/profile, source/lock/binary hashes, and repetition count.
5. **Distribution.** Repeat the supported installation on the required fresh account and other device. Report local, CI, public-source, public-release, and installed-device evidence with their own receipts. A freshly source-built compiler receives its own observed hash and qualification; reuse a prior compiler profile only when its admitted identity matches.

For API lookup, load the real consumer definitions entry. A launcher can defer the CLI and produce a different API context. Resolve compiler search paths before a child process changes directories; test the actual library layer as well as the stdlib layer when custom or relative paths are supported.

When an enclosing run fails after individual commands succeed, preserve both results and their original timestamps. A later current-parity check earns its own receipt. Keep the release and project acceptance gate open until its entire required workload passes.
