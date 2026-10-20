# Representative Grant build inputs and source controls

This review package contains the complete default Grant source/dependency closure,
300/500-model query and association fixtures, original acceptance contract,
complete-build worker/reader, origin reconstruction, MIT notice, and retained audits.
The first selected workload is Linux/SQLite/300 models/debug, with 900 operations,
4,800 field checks and 900 association edges. The strict compiler and whole-build
memory requirement is below 2,000,000,000 bytes. Accepted target cells: **0/144**.

The outer archive is 2,908,563 bytes, SHA-256
`aebd690e5978aa6373e2177aa7ee2d5bcb8b7e064cc50aee18ae9c4d53fc5601`.
Its contents manifest is
`292430bfd276814ed8bfda4e0edb16aa04e582a9bc92bd927c6c4bf2a9beb9c6`.
`PUBLICATION_PINS.json` binds these bytes and the standalone verifier.

The checked [source workflow](../../.github/workflows/grant-source-package-controls.yml)
verifies source, interpreter and package pins before execution. For the manual
command below, first select an interpreter whose exact version and resolved executable
SHA-256 match a `source_python_profiles` entry in `PUBLICATION_PINS.json`, and verify
that `verify_publication.py` has SHA-256
`c7bb0b45e7df41fd45ba28f498b109fce797772bfe4707898c92401bd1bb3041`.
The Xcode 3.9.6 entry is a local source-review profile; the Linux 3.12.3 and macOS
3.15.0 entries are observed hosted-control profiles. Full native closure is separate.

From a checkout of this SDK, verify and physically reproduce the package:

```sh
python3 -I -S -B tools/grant_compile_acceptance/verify_publication.py \
  --archive tools/grant_compile_acceptance/grant-linux-first-build-publication-v100.tar.gz \
  --archive-sha256 aebd690e5978aa6373e2177aa7ee2d5bcb8b7e064cc50aee18ae9c4d53fc5601 \
  --contents-sha256 292430bfd276814ed8bfda4e0edb16aa04e582a9bc92bd927c6c4bf2a9beb9c6 \
  --output /absolute/fresh/Grant-package-review
```

The extracted package README supplies source-test CLI arguments, exact origins,
licenses, retained audit findings, and the explicit portable-helper mapping. Its
unchanged 13 original preparation tests and 16 complete-build reader tests run in
both Python modes inside a fresh path containing spaces. The helper normalizes
only the five dependency-alias tar header modes; regular bytes/modes and alias
targets retain their original identity requirements.

The source workflow verifies the archive, rejects a changed archive, and runs
those four cohorts using a version/hash-bound interpreter on each hosted platform.
These are packaging and source/reader controls. Ordinary Alpha installation,
frozen dependency installation, native projection/canaries, actual compilation,
executed model behavior, whole-build controls, all 144 cells and supported release
qualification remain separate requirements. Historical absolute paths in the
included receipts identify their original evidence; runtime paths are supplied
through the documented portable workspace and actual build CLI arguments.

The frozen bundled wrapper retains its original `actual_Linux_execution` pending
label. The workflow records actual execution independently in
`CI_SOURCE_EXECUTION.json` using the observed platform and
`actual_linux_source_cohorts_executed`; hosted Linux acceptance requires that derived
field and the complete four successful raw cohort receipts.
