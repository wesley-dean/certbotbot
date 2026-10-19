# Release Verification

The release pipeline calculates a semantic version from Conventional Commits
without creating a tag, validates the exact bytes intended for publication, and
creates the GitHub release/tag only after validation succeeds.

The expected sequence is:

1. calculate the version with `bitshifted/git-auto-semver` and
   `create_tag: false`;
2. run maintained-source checks;
3. run `make deps` and `make deps-check`;
4. build all artifact flavors with the calculated version;
5. execute the Bats behavior contract against the exact generated artifacts;
6. execute representative compatibility behavior under Bash 4.3;
7. verify every `.sha256` checksum;
8. attest all release files; and
9. create the GitHub release and tag with all six artifacts attached.

New releases publish only `.sha256` checksum companions.  Historical releases
that contain `.256` companions remain unchanged.  A consumer that verifies
artifacts across release generations should request `<artifact>.sha256` first and
may use `<artifact>.256` only when the preferred companion is confirmed absent.
Transport, TLS, authorization, server, malformed-content, and checksum-verification
failures remain failures rather than fallback conditions.

Published checksum companions are release verification data.  They do not replace
the committed SHA-256 digests that authorize bashdeps or dependencies declared in
`dependencies.txt`.

The Conventional Commit mapping used by the selected SemVer action supports the
full semantic progression: `feat` increments minor, `BREAKING CHANGE` increments
major, and supported maintenance types increment patch.

A release failure before the final step should leave no newly-created release
tag.  This ordering is deliberate: publication is the consequence of successful
validation, not a prerequisite for it.

See ADR-012 for checksum companion naming and historical-read compatibility.
