# Linux kernel budget qualification

These controls qualify a finite Linux container environment for the memory
budget and installation-provenance tooling. The SDK's installed package and
Grant's complete-build acceptance retain their respective contracts.

The first CI run records a candidate runner profile. A read-only metadata
collector hashes the installed Docker client, the live daemon executable,
Python, Bash, sudo, sha256sum, and timeout. It records the daemon's reported
version and Git revision, kernel, cgroup controller, and GitHub image identity.
Reading the daemon executable uses the hosted VM's administrative metadata
access. This phase starts zero containers and earns zero workload acceptance.
The missing reviewed profile produces exit 2 while retaining the candidate
artifact, so pending qualification remains a failed gate.

Review the candidate and commit its exact `profile` object in
`runner_profile.json` with format `atlas-linux-runner-profile-v1`. The next
job compares every observed field before admitting the Docker workloads.
Profile drift refuses before workload entry. The runner image and kernel
remain an explicit observed platform boundary.

The workload source manifest binds seven Python files by SHA256. Its exact
54 source controls already ran in both ordinary and optimized modes on the
recorded Darwin ARM64 development profile. The Linux workflow adds actual
kernel behavior: separate capped ordinary and optimized containers, a real
OOM allocation, an uncapped refusal, and external terminal verification.
The driver records and removes only its exact owned container identities.

Workloads use the digest-pinned Python image, read-only source and cgroup
mounts, one CPU, 64 process slots, zero swap, a bounded temporary filesystem,
and a page-aligned memory ceiling. The OOM control needs an admitted probe,
exit 137, and Docker's actual OOM marker. An uncapped container must refuse
before loading the test modules. Raw results, inspections, and cleanup
readbacks are retained as CI artifacts.

`memory.peak` measures charged memory for the current cgroup and descendants.
It differs from compiler-process RSS. The kernel also documents temporary
limit overshoot and the ownership of shared or migrated pages. Actual peak,
event counters, process membership, short-lived children, sibling isolation,
and complete terminal evidence need their own qualification before this
measurement can participate in a complete Grant build contract. See the
[kernel memory controller documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html).

Grant's default-feature 300/500-model target remains strictly below
2,000,000,000 bytes for both required memory metrics across its complete
matrix. These installation-protocol controls alone accept zero Grant cells,
execute zero Homebrew commands, and establish zero ordinary compiler
installations. Their runtime reports preserve those scopes explicitly.
