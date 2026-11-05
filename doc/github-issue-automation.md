# GitHub Issue and Kanban Automation

This guide documents the repository's administrative issue metadata and
reporting scripts. It is **not** part of certbotbot's certificate producer,
read-only client, OCI image, or released Bash artifacts. Run the commands
below from the repository root and supply only the permissions required
for the selected operation.

## GitHub issue metadata synchronization

The repository includes a GitHub Actions workflow and two independent Bash
scripts for synchronizing GitHub's native issue relationships and optionally
GitHub Projects v2 Status. This is repository administration tooling, not part
of the certificate producer or its releases.

Prerequisites for local use: `gh`, `jq`, and an exported `GH_TOKEN` with
appropriate permissions. In Actions, native relationships use the built-in
token with `issues: write`; only optional Projects synchronization requires
the repository secret `GH_TOKEN`. The workflow accepts no dispatch inputs; issue events
process the affected issue, and a manual dispatch or weekly scheduled run
processes the entire backlog.

```bash
export GH_REPO=wesley-dean/certbotbot
bash scripts/update_issue_parent_child_relationships.bash --issue 100
bash scripts/update_issue_parent_child_relationships.bash --all

# Projects integration is optional and disabled by default:
export PROJECT_NUMBER=0
bash scripts/update_issue_project_status.bash --issue 100

# To enable Projects v2, set a positive project number and ensure GH_TOKEN
# has permission to update the target Project.
export PROJECT_NUMBER=12
export PROJECT_OWNER=wesley-dean
bash scripts/update_issue_project_status.bash --all
```

Set repository Actions variable `PROJECT_NUMBER` to the appropriate positive
GitHub Projects number to enable project synchronization. Unset, empty, or
`0` skips the Projects job without affecting relationship reconciliation.
An optional `PROJECT_OWNER` variable overrides the repository owner.

Run the isolated mock checks with
`bash tests/issue-metadata-sync.bash`. Existing native parents are not
silently replaced when their Markdown declaration disagrees; failures
must be investigated. Project synchronization mirrors only status and does
not update approvals, issue closure, or milestones. See
[ADR-044](adr/ADR-044-github-issue-metadata-synchronization.md).

### Native issue dependency synchronization

To add native GitHub blocking relationships, write a dedicated level-two `Blocked by` section with one bare issue reference
per line, for example `- #89` followed by `- #90`. References in
`Dependencies and Governing Decisions` are NOT blocking dependencies.
Dependency synchronization is temporarily disabled in Actions pending audit
and cleanup of incorrectly created relationships.
The script adds missing native blockers, verifies them, and preserves existing
relationships; it never removes them or infers dependencies from parentage.

```bash
export GH_REPO=wesley-dean/certbotbot
# GH_TOKEN must be available, as with the other issue scripts.
bash scripts/update_issue_dependencies.bash --issue 100
bash scripts/update_issue_dependencies.bash --all
# Offline mocked checks:
bash tests/issue-dependencies-sync.bash
```

The dependency synchronization job remains suspended in Actions pending
review of previously created relationships. The dedicated read-only PR test
workflow still checks its mocked behavior. See [ADR-045](adr/ADR-045-native-issue-dependency-synchronization.md).

### Read-only Markdown Kanban report

Generate a Markdown board directly from live GitHub Issues:

```bash
GH_REPO=wesley-dean/certbotbot bash scripts/render_issue_kanban.bash > kanban.md
# Or use --repo owner/repo; gh CLI authentication is required.
```

The report displays Todo, In Progress, and Done columns, with High, Medium
(default/normal), and Low priority rows. Only issues currently carrying the
`approved` label appear, and declined/not-planned closures are excluded.
Approved technical tasks are indented under an approved parent story when
they share a cell; other approved tasks are included in a standalone/cross-lane
group rather than being hidden or misrepresented. This is a point-in-time
read-only report, not a GitHub Projects board or a new source of lifecycle
state. Run `bash tests/issue-kanban-report.bash` for mocked validation.

### Publish Kanban into a managed issue

The metadata workflow also publishes the Markdown board to the exact issue
title `Development Kanban` on issue events, manual dispatch, and schedule.
It creates the issue if no exact title matches. Once created, the issue body
includes a `managed-by` marker, so future runs can safely replace its
contents. An existing issue with the same title but no marker is **not**
overwritten; duplicate exact-title matches also fail closed.

Local execution (requires `GH_TOKEN` with `issues: write`):

```bash
GH_REPO=wesley-dean/certbotbot bash scripts/publish_issue_kanban.bash
# Override the title for manual use:
bash scripts/publish_issue_kanban.bash --title 'Development Kanban'
```

The generated issue is deliberately unlabeled and unapproved. It is excluded
from the board, and the Actions job skips issue events for the generated title.
Use `bash tests/issue-kanban-publisher.bash` for offline mock checks.


## Related governance

- [Approval-label authority](adr/ADR-019-authoritative-approval-labels.md)
- [Issue metadata synchronization decision](adr/ADR-044-github-issue-metadata-synchronization.md)
- [Native dependency synchronization decision and safety suspension](adr/ADR-045-native-issue-dependency-synchronization.md)
