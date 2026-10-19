# Admit native libraries at Ruby entrypoints

Crystal applications can need GMP, OpenSSL, SQLite or other native libraries beyond the compiler's own dependencies. A passing small example qualifies that example's native closure. Qualify each application's actual link and loaded images before accepting its budget run.

The local candidate supports toolchain profile **schema 2** for this job. Schema 2 requires `native_component_manifest_sha256` and an explicit `MEMORY_BUDGET_NATIVE_COMPONENT_LOCK`. SDK versions that support only schema 1 refuse the new profile. Existing schema-1 compiler profiles retain their existing scope; the new helper refuses a native lock or native hash attached to schema 1. Counter protocol 1 stays unchanged.

## Prepare the reviewed identity

Keep native tooling configuration under `performance/`. Use physical versioned directories, such as an installed release's `lib` directory or a package's `Cellar/gmp/6.3.0/lib`. Every search directory receives its complete recursive file, directory and symlink roster. Each file's bytes and permissions are pinned; each alias has exact link text and a separately admitted physical target. The helper rejects additions, omissions, changed files, changed links and conflicting search aliases. A different ordinary prefix receives a new reviewed manifest and profile hash.

Create `performance/native-roots.json` with this shape, replacing the example paths with actual physical installed directories:

```json
{
  "profile": "app-native-build-1",
  "environment": {
    "CRYSTAL_LIBRARY_PATH": ["/ordinary/prefix/lib", "/ordinary/gmp/6.3.0/lib"],
    "DYLD_LIBRARY_PATH": ["/ordinary/prefix/lib", "/ordinary/gmp/6.3.0/lib"],
    "PKG_CONFIG_LIBDIR": ["/ordinary/prefix/pkgconfig"],
    "PKG_CONFIG_PATH": ["/ordinary/gmp/6.3.0/lib/pkgconfig"]
  },
  "files": ["/ordinary/gmp/6.3.0/include/gmp.h"],
  "loader_trace": false
}
```

The generator gives each physical directory one roster owner. A nested pkg-config search directory is covered by its parent library's complete recursive roster. Configuration values preserve the reviewed search order and clear an explicitly empty pkg-config search list.

**Run from the SDK checkout, or the installed bundle root, with the admitted Ruby:**

```sh
ruby scripts/prepare_native_manifest.rb /app/performance/native-roots.json > /app/performance/native-component.json
```

Review the generated platform identity, full rosters, modes and targets against the installed packages and their verified release provenance. Pin the complete file's SHA-256 in a schema-2 toolchain profile. Keep that profile's existing exact compiler, declared wrapper, standard library, Ruby and dependency-tool hashes. Record the profile SHA independently in CI.

**Run from the application root, using its reviewed profile:**

```sh
MEMORY_BUDGET_TOOLCHAIN_LOCK="$PWD/performance/toolchain.native.json" \
MEMORY_BUDGET_TOOLCHAIN_PROFILE_SHA256="<reviewed-profile-sha256>" \
MEMORY_BUDGET_NATIVE_COMPONENT_LOCK="$PWD/performance/native-component.json" \
ruby performance/vendor/memory_budget/scripts/budget.rb spec -Dwithout_mt
```

The manifest has its own schema 1, distinct from toolchain profile schema 2. It binds the actual kernel platform identity. Header files and other provenance files can be pinned through `files`; the admitted compiler/Apple SDK provider and native install provenance retain their separate source-bound qualification.

## Why the shared helper restores the environment

Apple Ruby can clear `DYLD_LIBRARY_PATH` on exec. `budget.rb` admits the original wrapper and publishes the exact selected profile. `run_specs.rb` rechecks that selection and the native manifest, restores `CRYSTAL_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`, `PKG_CONFIG_LIBDIR` and `PKG_CONFIG_PATH` immediately before the compiler/spec process, and checks the native identity again after it finishes. The wrapper remains part of the admission even when the bootstrap delegates directly to its backend. Compiler commands default to one explicit code-generation thread and preserve caller-provided thread flags and program arguments after `--`.

The app runner template uses the same helper before and after each build, spec, regression and verifier child. Its report includes the toolchain schema and native manifest SHA. The frozen dependency installer requires schema 3, adding the [Git provider admission](git-provider.md) to these native identities. It restores the approved environment for Minecart version and install children and rechecks native files, Git providers and Minecart bytes after each child. App-owned native link flags, spec helpers and database isolation remain app configuration. A returned native identity keeps an immutable manifest and rechecks its pinned bytes and physical roster before reuse.

## Acceptance evidence

Run a named native binary directly first to establish its emitted linker arguments, actual loaded images and normal behavior. Then qualify the ordinary SDK spec entrypoint and ordinary app target under the same pinned native identity. Use `loader_trace: true` in a separately pinned diagnostic manifest to restore `DYLD_PRINT_LIBRARIES=1` at the same boundaries; this changes the manifest and profile identity.

Require the expected provider images and hash every ordinary loaded image; bind OS images to the reviewed OS/SDK provider. The manifest validator pins files and search paths. Runtime loaded-image coverage is separate evidence from those static checks. Preserve altered-file/link/roster controls, a path containing spaces, normal behavior and the same-binary allocation regression. Actual native entrypoint execution, ordinary public installation, clean-account installation and a separately installed device keep their own acceptance states.


## Private Darwin and ELF helper candidate

This exact-source candidate retains package version0.1.1 and remains unreleased. Its base is public commit `a7e57b1559e0c2457d334a843bcc487fdbaeebb2`; candidate source and package hashes identify the changed bytes. Native manifest schemas are independent of the package version and toolchain-profile schema.

The native schema1 API remains `NativeEnvironment.admit(expected_sha256, manifest_path).environment` with the existing Darwin environment: `CRYSTAL_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`, `PKG_CONFIG_LIBDIR`, and `PKG_CONFIG_PATH`. `loader_trace:true` selects `DYLD_PRINT_LIBRARIES=1`; false explicitly removes that trace variable. Valid schema1 behavior remains the legacy contract.

Native schema2 requires exactly the schema1 fields plus `loader_family`. The actual platform from `Etc.uname` must match: Darwin uses `darwin_dyld`; Linux uses `elf_ld`. Its environment map uses the same four keys, with `LD_LIBRARY_PATH` replacing `DYLD_LIBRARY_PATH` on ELF. Tracing selects `DYLD_PRINT_LIBRARIES=1` on Darwin and `LD_DEBUG=libs` on ELF. False tracing explicitly clears the selected trace. Before restoring these admitted values, schema2 returns nil removals for inherited `LD_` and `DYLD_` overrides. Parent `ENV` remains unchanged. Callers revalidate the held identity and obtain a fresh overlay before each process boundary.

The manifest preparation CLI remains `ruby scripts/prepare_native_manifest.rb CONFIG.json`. A schema1 config keeps exactly `profile`, `environment`, `files`, and `loader_trace`. A schema2 config adds required `schema_version:2` and `loader_family`; its search arrays and provider roots must be physical, absolute, complete and reviewed. The output is a candidate manifest whose exact hash is reviewed separately. Existing toolchain profile schema2/3 must require that hash through `native_component_manifest_sha256`; the old helper refuses the new native schema2 capability. Compiler/backend, stdlib, Ruby and Git admission are still separate inputs.

The private source includes the original112 portable tests and a separate27-case `test/native_platform_behavior.rb` cohort. Its old schema1 fixture is exact a7 source. The latter exercises physical fixture files, modes, aliases and environment restoration with explicit logical Darwin/Linux platform inputs. Its Ruby child commands are metadata/fixture controls. Passing those cases establishes Ruby helper behavior; actual ELF linking, loaded provider images, ordinary Linux toolchain installation,39+39 Crystal specs and same-binary tutorial0/1 still require their native jobs.

Run the complete portable cohort with `ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'`. Then set `MEMORY_BUDGET_TEST_OUTPUT_PARENT` to an owned evidence parent and invoke `ruby test/native_platform_behavior.rb FRESH_EVIDENCE_PATH` beneath that parent. Both commands require a separately admitted exact Ruby runtime. The existing pinned Linux portable CI route invokes both cohorts, using fixture executables and explicit exec-capable temporary storage. Public installation support, a release, a fresh account or device, and first-class Alpha runtime integration each retain their own acceptance gate.
