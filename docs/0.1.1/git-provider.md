# Admit Git for frozen dependency installation

Toolchain profile **schema 3** adds the actual Git provider to the existing compiler, Ruby and native-library admission. The ordinary frozen installer and the CI source-identity command require schema 3. Compiler profiles 1 and 2 retain their documented compiler/native scope. Older SDKs refuse schema 3 instead of silently ignoring the new required capability.

This is an unreleased source candidate. The native Mini's installed Git backend, version, 196 helper entries and three external helper targets have separate actual readback evidence. The complete schema-3 SDK installation/spec workflow, public network fetching, a clean account and public installation on another device still need their own acceptance.

## Prepare a reviewed candidate

Run from the SDK repository or installed bundle root. Start with an independently verified Git installation receipt. Use the actual native backend; Apple's `/usr/bin/git` launcher alone does not identify the executable it selects.

Create a tool configuration file outside `shard.yml`:

```json
{
  "profile": "my-git-provider-v1",
  "git_path": "/absolute/physical/git",
  "git_sha256": "REPLACE_WITH_THE_REVIEWED_64_CHARACTER_SHA256",
  "git_version": "REPLACE_WITH_THE_EXACT_FULL_VERSION_OUTPUT",
  "delegate_directory": "/absolute/private/tool-profiles/git-bin"
}
```

The parent directory of `delegate_directory` must already be a physical directory. The helper creates a new account-owned directory with mode 0700 containing exactly one `git` symlink to the reviewed backend. An existing delegate must already match that exact shape.

```sh
ruby scripts/prepare_git_manifest.rb git-roots.json > git-provider.json
```

The helper checks the supplied backend hash before invoking metadata commands. It reads the actual version and helper path, records every helper file, directory and symlink, and separately pins every external target of a helper alias. It validates the complete roster again before returning its candidate. Review the candidate and hash its exact saved bytes. Candidate generation is preparation; it does not admit that candidate into another profile.

## Use it through ordinary entrypoints

Extend the separately reviewed native profile with these fields:

```json
{
  "schema_version": 3,
  "git_provider_manifest_sha256": "REPLACE_WITH_THE_REVIEWED_MANIFEST_SHA256"
}
```

Keep the existing compiler, wrapper, standard-library, Ruby, native-manifest and Minecart identities. Schema 3 requires both native and Git manifests. Select their explicit paths:

```sh
export MEMORY_BUDGET_TOOLCHAIN_LOCK=/reviewed/toolchain.json
export MEMORY_BUDGET_NATIVE_COMPONENT_LOCK=/reviewed/native-components.json
export MEMORY_BUDGET_GIT_PROVIDER_LOCK=/reviewed/git-provider.json
ruby scripts/toolchain_profile.rb --json
```

Run these commands from the application root, using the installed SDK paths:

```sh
ruby performance/vendor/memory_budget/scripts/install_frozen_dependencies.rb
ruby performance/vendor/memory_budget/scripts/source_commit.rb
ruby performance/run_memory_budgets.rb --self-test
```

The installer retains `install --frozen --skip-ai-docs --jobs=1` and preserves the manifest/lock bytes. It verifies Git, the selected profile, native files and Minecart around the version/install children. A Git or manifest change after Minecart exits still fails acceptance. The source-identity command uses the admitted Git route and requires an exact 40-character commit id. The app runner resolves its toolchain before asking Git for the source commit and revalidates the selection afterward.

The private delegate leads `PATH`; `GIT_EXEC_PATH` selects the pinned helper directory. Inherited `GIT_*` overrides are cleared. The candidate uses explicit isolated system/global config, disables interactive prompting and permits HTTPS/file protocols. Private SSH/credential-helper workflows need their own reviewed provider and configuration contract. Git's additional native-library dependencies retain the platform/native-provider qualification boundary; a helper-file roster alone does not prove a new device's link or runtime behavior.

## Prove refusal and restoration

Keep actual output and source/tool identities for an ordinary successful install. Change a helper, backend, external target or delegate alias and require refusal; restore it and require success. Exercise a Git change during Minecart's version call and during installation. Preserve the original worker result if transport or collection fails. Distinguish the compiler/native scope of legacy profiles, the full schema-3 source controls and an actually installed schema-3 consumer.
