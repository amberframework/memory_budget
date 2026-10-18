# Memory budgets in CI

The required job executes a declared scenario roster, verifies raw typed evidence independently and preserves failed runs. A label saying passed supplies context; numerical comparison and coverage determine acceptance.

## Where the examples go

Keep the application contract in `performance/memory_budget.json`, its functional examples under `spec/performance/`, the runner at `performance/run_memory_budgets.rb`, and CI wiring in `.github/workflows/memory-budgets.yml`. Extend the existing spec helper. Package/toolchain pins and the app's checksum-bearing dependency lock stay committed with their respective owners.

**Run from: the application repository root, with its verified memory kit installed.**

```sh
/usr/bin/ruby performance/run_memory_budgets.rb --self-test
```

The candidate Amber command `amber performance check --self-test` invokes that same runner. Source-verified command availability and public installed availability are separate states.

The runner builds one named spec executable, runs the normal workload and a real injected allocation regression, and gives raw observations/capabilities to the common typed checker. It binds the spec/checker executables, source, dependencies, lock, policy and compiler profile by hash. Source or executable drift fails acceptance. A common verdict exits 0 only for complete pass and 2 for failed acceptance; preflight/setup refusals may exit 1.

## Required controls

- Sufficient allowance passes while the real operation's functional assertions pass.
- An actual added allocation or tight limit fails with the expected measurement and scenario.
- Missing/duplicate scenarios or observations, empty rosters, unsupported capabilities and blank identities fail.
- An over-budget observation labeled passed remains rejected by independent verification.
- A changed source, dependency, policy, executable or vendored bundle fails identity checks.

Admit each runner's backend, standard library, host profile and measuring adapter before making the job required. Keep ordinary-suite behavior and dedicated instrumentation behavior visible. Release jobs consume the accepted source commit and an admitted release profile. Remote execution, protection settings, public packaging and second-device installation are deployment gates with actual receipts.

## Documentation integrity

The SDK owns `docs/corpus.json` and `docs/corpus-manifest.json`. `scripts/docs/manage_corpus.py` verifies the exact nonempty corpus roster and source hashes, writes deterministic Amber projections, and checks their parity. The website holds a source pin and complete public corpus projection; its standalone `scripts/memory_budget_docs.py` checks the bytes in its own checkout. Missing, modified, stale-version or unexpected projection files fail before publication.

## Dependency and source tool admission

The ordinary dependency installer and CI source-identity command require the [schema-3 Git provider](git-provider.md) alongside the compiler/Ruby/native identities. Configure the three explicit lock paths in the admitted runner environment. The workflow records HEAD through `scripts/source_commit.rb`; the app runner also admits its toolchain before asking Git for HEAD. The default legacy compiler profile remains a narrower compiler profile until its full runner admission is prepared.
