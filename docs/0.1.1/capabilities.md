# Choose a memory measurement

Choose the owner and time window before choosing a number. Requested allocation bytes, live blocks and physical pages are overlapping views, so each has its own budget.

| Measurement | Owner/window | Intended use and qualification |
| --- | --- | --- |
| Fiber allocation calls/requested bytes | Crystal allocations on the current fiber inside a block | Deterministic synchronous operations; requires admitted counter protocol 1 |
| Joined-process allocation traffic | All Crystal allocations during an isolated process window | Workers finish inside the block; concurrent unrelated work also counts |
| Fixed plus per item | Checked fixed allowance plus cost times explicit count | Exercise a nonempty list of representative input sizes; measured sizes define the evidence |
| C calls/requested bytes | Admitted C instrument and exact windows | Coverage/loss controls must pass; cold and warm scopes remain distinct |
| C live bytes by allocation owner | Live allocation map and recorded release owner | Useful when optimized frees lose the original Crystal source frame |
| SQLite cache | An actual live database connection | Use verified connection status; a global successful zero does not establish an empty connection cache |
| Process footprint/RSS and lifetime peak | Whole process and declared platform/lifetime | Darwin physical footprint and Linux RSS have distinct metrics; a fresh process provides an independent scenario peak |
| Compiler memory | Exact source/toolchain/build/model/profile | Keep semantic diagnostics, complete code generation, linking and whole-build accounting explicit |

The SDK's original admitted profiles cover Darwin ARM64 and a separate Linux AMD64 SDK container. Compiler binary/standard library hashes and capability identities must match. A missing profile remains a qualification requirement. Mobile devices, asynchronous helpers and other app journeys require their own evidence.

The original C comparison table retains six SQLite cold-scope failures and three optimized CoreFoundation free-source failures. Supported checks use matching broad cold scope, live connection cache and allocation-owned release. Lost map coverage fails before comparison with a limit. A reporting program's exit 0 establishes completion; the typed verdict and required roster establish acceptance.

Grant's new default-profile target requires complete 300/500-model builds below 2,000,000,000 bytes for both compiler RSS and admitted whole-build memory across its full required matrix. That target remains unmet. A semantic-only result or an optional lean profile keeps its own label. Module opt-out savings require source-verified inclusion APIs, paired measurements and preserved behavior.
