# Security Policy

## Scope

template-bash is a personal open source starter rather than a commercially
supported security product.  The project nevertheless treats vulnerability
reports seriously because derived repositories may inherit build, dependency,
CI, release, and runtime patterns from this template.

The starter's security posture is intentionally bounded.  Accepted ADRs describe
specific architectural guarantees and limitations, while
`doc/threat-modeling.md` provides a reusable exercise for projects whose domain
introduces sensitive data, untrusted input, destructive operations, privileged
authority, network access, or other security-relevant boundaries.

Projects derived from this template should rewrite this policy before their first
release so it reflects their actual maintainers, supported versions, security
claims, disclosure channel, and response expectations.

## Reporting a Vulnerability

Please do not disclose a suspected vulnerability in a public GitHub issue before
coordinated disclosure.

Send vulnerability reports to:

[security_vulnerability_disclosure@wesleydean.com](mailto:security_vulnerability_disclosure@wesleydean.com)

Useful reports include the affected template-bash release or commit, Bash version,
operating system, a minimal reproduction, expected behavior, actual behavior, and
the security impact.  Please avoid including real production credentials, tokens,
or private data when a synthetic reproducer will demonstrate the issue.

Good-faith attempts will be made to acknowledge, investigate, and address reports
within a reasonable period.  If communication stalls or a report remains
unresolved, please continue coordinating disclosure through the private contact
above rather than publishing sensitive technical details solely because a fixed
number of days has elapsed.

Once disclosure is appropriate, a public issue, advisory, release note, or other
public record may be created as part of the coordinated resolution.

## Security Expectations

Security-sensitive changes should identify the boundary being protected, the
assets and authority involved, supporting evidence, and residual risk rather than
relying on a broad claim that a change is "secure."

Every new dependency should be treated as an expansion of the trusted computing
base.  Digest pinning and checksum verification help establish acquisition
integrity; they do not establish behavioral safety or appropriate privilege.

See ADR-015 for dependency attack-surface review, ADR-016 for threat-modeling
expectations, and `doc/threat-modeling.md` for the reusable exercise.
