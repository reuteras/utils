# release-auditor

AI-powered security auditing of GitHub releases, with automated follow-up
lockfile scanning for 7 days after each audit.

## Overview

When a new release appears in your GitHub notifications, `audit.sh` invokes
Claude Code to perform a structured security analysis: changelog review, commit
diff inspection, CVE cross-referencing via OSV, and supply chain provenance
checks. Claude also saves all lockfiles from the release tag to disk.

`scan-lockfiles.sh` then runs daily (via cron) for 7 days, re-scanning those
lockfiles with `osv-scanner` to catch advisories published after the initial
audit.

```text
GitHub notifications
       ↓
  audit.sh  →  Claude Code (CLAUDE.md)
                 ├── Diff & changelog analysis
                 ├── CVE check via OSV
                 ├── Provenance & tag integrity
                 └── Saves lockfiles to disk
                          ↓
              scan-lockfiles.sh  (daily, 7 days)
                 └── osv-scanner per lockfile
```

## Directory structure

```text
release-auditor/
├── CLAUDE.md               # Claude Code instructions
├── audit.sh                # One-shot release auditor (uses Claude)
├── poll-notifications.sh   # Polls GitHub notifications, calls audit.sh
├── scan-lockfiles.sh       # Daily lockfile scanner (no Claude required)
├── migrate-seen.sh         # One-time migration for pre-v2 seen.json entries
├── state/
│   └── seen.json           # Tracks audited releases and scan windows
├── reports/
│   └── {owner}__{repo}__{tag}/   # Reports saved per release
│       ├── audit-YYYY-MM-DD.txt  # Initial audit report
│       └── scan-YYYY-MM-DD.txt   # Daily lockfile scan reports
└── lockfiles/
    └── {owner}__{repo}__{tag}/   # Lockfiles saved per release
        ├── poetry.lock
        ├── package-lock.json
        └── ...
```

## Prerequisites

| Tool          | Purpose               | Install                                    |
|---------------|-----------------------|--------------------------------------------|
| `claude`      | Claude Code CLI       | `npm install -g @anthropic-ai/claude-code` |
| `gh`          | GitHub CLI            | `brew install gh`                          |
| `osv-scanner` | Lockfile CVE scanning | `brew install osv-scanner`                 |
| `jq`          | JSON processing       | `brew install jq`                          |
| `curl`        | HTTP requests         | pre-installed on macOS                     |

Authenticate before first use:

```bash
gh auth login
export ANTHROPIC_API_KEY=sk-ant-...   # or add to ~/.zshrc
```

## Usage

### Audit a single release

```bash
./audit.sh https://github.com/owner/repo/releases/tag/v1.2.3
```

Claude Code runs non-interactively, prints a structured report to stdout, saves
lockfiles to `lockfiles/`, and registers the release in `state/seen.json` with
a 7-day scan window.

### Poll GitHub notifications

```bash
./poll-notifications.sh
```

Fetches all unread release notifications from GitHub and calls `audit.sh` for
each one that has not already been audited.

### Run the daily lockfile scanner

```bash
./scan-lockfiles.sh
```

Scans all lockfiles for releases still within their 7-day window. Prints a
report per release with any newly published CVEs.

### Set up cron

Run the notification poller hourly and the lockfile scanner daily:

```text
*/10 * * * * /path/to/release-auditor/poll-notifications.sh
0 7 * * * /path/to/release-auditor/scan-lockfiles.sh
```

Both scripts are silent when there is nothing new to report, so cron will only
send an email when a new release audit or changed lockfile findings are
detected. Reports are always saved to the `reports/` directory regardless.

## Report format

### audit.sh output

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RELEASE AUDIT: owner/repo @ v1.2.3
Released:      2026-05-29
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

VERDICT: LOW | MEDIUM | HIGH

SUMMARY
CHANGELOG ANALYSIS
COMMIT REVIEW
CVE / ADVISORY CHECK
PROVENANCE
LOCKFILES SAVED
RED FLAGS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### scan-lockfiles.sh output

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LOCKFILE SCAN: owner/repo @ v1.2.3
Scan date:     2026-05-31    Monitoring until: 2026-06-05
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Lockfile: poetry.lock
  Result:   VULNERABILITIES FOUND

  VERDICT: FINDINGS DETECTED — review above
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Supported lockfile formats

| Ecosystem    | Files                                                         |
|--------------|---------------------------------------------------------------|
| npm          | `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`            |
| Python       | `poetry.lock`, `requirements*.txt`, `Pipfile.lock`, `uv.lock` |
| Go           | `go.sum`                                                      |
| Rust         | `Cargo.lock`                                                  |
| PHP          | `composer.lock`                                               |
| Ruby         | `Gemfile.lock`                                                |
| Elixir       | `mix.lock`                                                    |
| Dart/Flutter | `pubspec.lock`                                                |
| Swift        | `Package.resolved`                                            |

`osv-scanner` handles most formats natively. `uv.lock`, `mix.lock`, and
`Package.resolved` fall back to per-package OSV API queries.

## Migrating from an older seen.json

If you ran `audit.sh` before lockfile saving was added, your `seen.json`
entries will be plain timestamp strings. Run the migration once:

```bash
./migrate-seen.sh
```

This upgrades all existing entries to the new object format and sets the expiry
to 7 days from the original audit timestamp. Lockfiles already saved to disk
are picked up automatically.

## Customisation with Claude Code

`CLAUDE.md` is the instruction file Claude Code reads on every run. Edit it
directly to adjust the audit scope, output format, or which lockfiles get saved.
Claude Code picks up changes on the next `audit.sh` invocation with no other
configuration needed.

To iterate on `CLAUDE.md` interactively:

```bash
cd /path/to/release-auditor
claude   # opens interactive session with CLAUDE.md already loaded
```
