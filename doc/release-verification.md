# Release Verification

The release workflow calculates a semantic version from Conventional Commits
without creating a tag, validates the **exact bytes intended for
publication**, and creates the GitHub release/tag only after all testing,
checksum verification, and attestation have succeeded. ADR-011 and ADR-036
govern these invariants.

## Release pipeline

The `.github/workflows/semver.yml` pipeline is triggered by pushes to `main`
and by explicit workflow dispatch. Publication is permitted **only** for
`refs/heads/main`. The workflow serializes runs by existing ref/workflow
concurrency, with `cancel-in-progress: true`.

1. **Calculate version** in a read-only job using the pinned
   `bitshifted/git-auto-semver` action and `create_tag: false`. The calculated
   candidate is passed as a job output. It is never recalculated by matrix
   runners or the publisher.
2. **Prepare release** in a read-only job. Validate maintained source
   (`make check`); prepare and verify pinned dependencies (`make deps` and
   `make deps-check`); and run one offline `make build VERSION=<candidate>`.
   Check the explicit three producer scripts **and one standalone client**,
   their Bash syntax and eight SHA-256-verified release files. No release credential is available to this job.
3. **Bind the handoff** using `ci/producer-handoff.bash create`. The manifest
   records the workflow commit SHA, run ID, run attempt, version, build
   metadata and **all four** checked executable hashes. Its SHA-256 is
   transmitted separately as a preparation-job output. The verified files
   and manifest are uploaded once as a **one-day retained**, same-run
   GitHub Actions artifact.
4. **Run six independent verification jobs:** three complete Bats suites
   using `make test-one TEST_FLAVOR=...`, plus three minimum-runtime
   checks under Bash 4.3 using `tests/compat-bash43.bash`. The exact
   variants are `development`, `ordinary` and `minified`. All suites
   use `fail-fast: false`, so a failed matrix leg does not cancel
   independent diagnostic evidence. Each runner restores executable mode
   only after rejecting symlinked files, then verifies the downloaded
   manifest and all release-file hashes against trusted job outputs and
   its own source/run/attempt/version. A test-only target **never**
   rebuilds the handed-off executable. The same verification additionally
   exercises the separately shipped client via real tar/gzip fixtures and
   mocked read-only S3 from an isolated runtime directory.
5. **Apply a strict unprivileged release gate.** The candidate version,
   preparation, entire Bats matrix and entire Bash 4.3 matrix must all
   report `success`. A failed, skipped, cancelled or missing required
   result cannot authorize publication.
6. **Publish only from the final privileged job.** With the gate
   successful and `github.ref` equal to `refs/heads/main`, download the
   exact same candidate set and re-verify its SHA-256 companions,
   manifest, commit/run/attempt and version. Only this job holds
   `contents: write`, `id-token: write`, `attestations: write` and
   `artifact-metadata: write`.
7. **Attest before creating the release.** The pinned `actions/attest`
   action attests **all four** `dist/*.bash` and all four `dist/*.bash.sha256`.
   Only after
   attestation succeeds does `softprops/action-gh-release` create the
   final tag/release with **the same verified executable and sidecar
   bytes**. The private CI handoff manifest is never a release asset.
8. **Complete the original `versioning` check.** A final unprivileged
   job retains that check name and reports success only if every
   prerequisite **including publication** succeeded. Its purpose is
   to prevent a renamed/reorganized workflow from reporting green
   before the release has actually been completed.

The test and release version handoffs are independent workflow runs.
A release must never reuse an artifact uploaded during a PR/test workflow
or an earlier workflow attempt.

## Current release inventory: two independent products

The exact release file inventory consists of three producer executables
and one separate client, each with its conventional SHA-256 sidecar:

- `certbotbot.dev.bash` and `certbotbot.dev.bash.sha256`
- `certbotbot.bash` and `certbotbot.bash.sha256`
- `certbotbot.min.bash` and `certbotbot.min.bash.sha256`
- `certbotbot-client.bash` and `certbotbot-client.bash.sha256`

The first **three** scripts continue to form the producer's Bats/Bash 4.3
representation matrix. The client has **one** ordinary-style executable
and separate shipped-artifact black-box tests. Both products share a
release version, commit/date provenance, and one exact, checksum-verified
release handoff. The handoff manifest binds all **eight** release files
to the same workflow identity and version. Extra or missing files,
stale `.256` companions, invalid Bash syntax, missing executable mode,
incorrect client identity/version, and changed bytes are rejected
before release publication.

An archive consumer has no Certbot, Route53 or renewal authority.
Its Bash 4.3 compatibility, independent checksum, plaintext extraction,
and malicious archive/no-clobber tests are mandatory quality evidence
alongside all existing producer flavor gates. Source files and vendored
libraries are never present at client runtime.

## Failure and trust boundaries

- A bad or ambiguous version, failure in any build/dependency/source
  check, incorrect Bash syntax, mismatched hashes, stale `.256` file,
  missing expected script, unexpected release file, or wrong
  commit/run/attempt causes an error **before** release publication.
- Every Bats suite and every Bash 4.3 variant runs independently.
  A successful sibling does not turn a failing matrix leg green.
- A failed artifact upload/download or absent/mismatched handoff
  manifest is a failed check, not an invitation to rebuild different
  bytes or use a mutable cache.
- The release publisher does **not** fetch from another workflow's
  artifact store, read untrusted PR artifacts, regenerate the files,
  or accept a checksum companion as proof of independent provenance.
- An attestation or GitHub release API failure prevents the final
  `versioning` check from succeeding. A remote release operation may
  have partial external side effects; do not assert transactionality
  beyond the actual GitHub API behavior.
- Publication permissions are confined to the gated main-branch
  job. The repository-wide default is `contents: read`.

## Checksums and historical compatibility

New releases publish only `.sha256` companions. Historical releases
containing `.256` companions remain unchanged. Consumers that verify
older releases SHOULD request `<artifact>.sha256` first and may
consult `<artifact>.256` **only after** a positively confirmed absence,
not after a transport, TLS, authorization, content or hash failure.

The release checksums do not replace committed SHA-256 digests
that authorize bashdeps or `dependencies.txt`.

## Version mapping and measured performance

The selected Conventional Commit mapping supports `feat` as minor,
`BREAKING CHANGE` as major, and supported maintenance types such as
`fix`, `docs`, `ci` and `test` as patch changes. The SemVer action
remains the single authority for candidate calculation.

Latency, runner-minute estimates, and artifact storage must be
measured separately. See
[CI parallelization performance and cost evidence](ci-parallelization-benchmark.md)
for pre-change observations, the intermediate PR workflow comparison,
and the post-merge release evaluation checklist.

See ADR-003, ADR-006, ADR-009, ADR-011, ADR-012, ADR-035 and ADR-036.
