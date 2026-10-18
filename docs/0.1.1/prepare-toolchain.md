# Prepare a profile for an ordinary installed toolchain

This unreleased helper gives a fresh installation a concrete profile-preparation path. It observes the installed files, retains their installation/source receipts, and checks metadata against reviewed expectations. It produces an **UNADMITTED** draft. Successful preparation is separate from spec, tutorial, native-library, clean-account and public-device acceptance.

## Start with the installation's provenance

Install Crystal Alpha and Minecart through their supported, checksum-verified release paths. Preserve the exact formula/tap commit or release recipe, the source/archive checksum, the installation receipt and the toolchain's expected full version output. A Homebrew user can locate a package with `brew --prefix agent-crystal` and retain its versioned `INSTALL_RECEIPT.json` and `.brew/agent-crystal.rb`. Use the actual installed paths returned by that installation.

A formula's source/archive hash identifies its input. A locally built compiler has its own executable hash. Review both identities; copying another machine's compiler profile does not establish either one. Ruby also needs its actual interpreter and launcher identities. Prepare the separately reviewed [native manifest](native-toolchain.md) and [Git provider manifest](git-provider.md) for this account and platform.

## Observe local bytes

Create `input-paths.json` outside `shard.yml`. The expected version strings come from the reviewed release/build receipts. The compiler version includes its full source commit and its complete LLVM/target lines.

```json
{
  "profile": "my-installed-alpha-build-v1",
  "compiler_entrypoint": "/absolute/installed/bin/crystal-alpha",
  "stdlib_root": "/absolute/versioned/share/crystal/src",
  "ruby_launcher": "/absolute/installed/bin/ruby",
  "minecart_path": "/absolute/installed/bin/minecart",
  "compiler_source_commit": "REPLACE_WITH_THE_REVIEWED_40_CHARACTER_SOURCE_COMMIT",
  "compiler_version": "REPLACE_WITH_THE_EXPECTED_FULL_MULTILINE_VERSION_OUTPUT",
  "minecart_version": "REPLACE_WITH_THE_EXPECTED_FULL_VERSION_OUTPUT",
  "native_manifest": "/absolute/reviewed/native-components.json",
  "git_manifest": "/absolute/reviewed/git-provider.json",
  "provenance_files": [
    "/absolute/receipts/formula-or-release-recipe.txt",
    "/absolute/receipts/INSTALL_RECEIPT.json"
  ]
}
```

From the downloaded, source/hash-verified SDK or its installed bundle:

```sh
ruby scripts/prepare_toolchain_profile.rb --inspect input-paths.json > observed-inputs.json
```

Inspection reads file bytes and the static wrapper declaration; it executes zero observed tools. Its output has status `UNREVIEWED_INPUTS` and contains `proposed_configuration`. Check the physical backend, wrapper, standard-library digest, actual Ruby, Minecart and manifest hashes against the retained receipts and the intended installation. The inspector retains the exact input-paths file as one of the provenance inputs. Observation alone supplies no admission.

After that input review, extract the configuration into a new file:

```sh
ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); abort "Review the observed inputs first" unless d.fetch("status")=="UNREVIEWED_INPUTS"; File.open(ARGV[1],File::WRONLY|File::CREAT|File::EXCL,0600){|f| f.write(JSON.pretty_generate(d.fetch("proposed_configuration"))+"\n")}' observed-inputs.json reviewed-inputs.json
ruby scripts/prepare_toolchain_profile.rb reviewed-inputs.json new-profile-review
```

The parent of `new-profile-review` must exist as a physical directory. The new directory has mode 0700. The helper pins every static input before metadata, runs exactly four metadata commands, and rechecks the same identities around each child:

1. The actual compiler backend's `--version`.
2. The backend's `env CRYSTAL_PATH`.
3. The pinned Minecart backend's `--version`.
4. The pinned native Git backend's `--version`.

Each child has a 15-second deadline and a 1 MiB output cap; the CLI allows 75 seconds of work plus 2 seconds for terminal cleanup. Retained manifests/provenance fit a 64 MiB aggregate cap. Native and Git context comes from the reviewed manifests. Changed tools, standard-library files, manifests, configuration, provenance or full versions refuse preparation. Raw metadata and a failure receipt remain available when a metadata check fails. An existing output directory keeps its own files.

## Review and extract the proposed profile

`new-profile-review/DRAFT_PROFILE.json` includes the proposed schema-3 profile, observed physical paths, exact configuration hash, retained receipt bytes, raw command hashes and terminal ownership. Its `UNADMITTED` envelope is deliberately rejected by the ordinary bootstrap.

Review the retained input bytes, four raw metadata outputs, compiler source/build provenance and native/Git closure. After that review, extract the inner profile into a new file and retain the printed SHA-256:

```sh
ruby -rjson -rdigest -e 'd=JSON.parse(File.read(ARGV[0])); abort "Expected an unadmitted draft" unless d.fetch("status")=="UNADMITTED"; File.open(ARGV[1],File::WRONLY|File::CREAT|File::EXCL,0600){|f| f.write(JSON.pretty_generate(d.fetch("proposed_profile"))+"\n")}; puts Digest::SHA256.file(ARGV[1]).hexdigest' new-profile-review/DRAFT_PROFILE.json reviewed-toolchain.json
export MEMORY_BUDGET_TOOLCHAIN_LOCK=/absolute/reviewed-toolchain.json
export MEMORY_BUDGET_TOOLCHAIN_PROFILE_SHA256=REPLACE_WITH_THE_PRINTED_REVIEWED_SHA256
export MEMORY_BUDGET_COMPILER=/absolute/installed/bin/crystal-alpha
export MEMORY_BUDGET_STDLIB=/absolute/versioned/share/crystal/src
export MEMORY_BUDGET_RUBY_LAUNCHER=/absolute/installed/bin/ruby
export MEMORY_BUDGET_NATIVE_COMPONENT_LOCK=/absolute/reviewed/native-components.json
export MEMORY_BUDGET_GIT_PROVIDER_LOCK=/absolute/reviewed/git-provider.json
ruby scripts/toolchain_profile.rb --json
```

The last command exercises normal admission with the reviewed profile. Follow it with the ordinary frozen installer, installed bundle/docs verification, SDK specs and the [same-binary tutorial control](fiber-budget.md). Keep their actual output, compiler/native loaded-image evidence and source-after identities. Those accepting runs establish the profile's usable scope; draft preparation establishes its reviewable inputs.
