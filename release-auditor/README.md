# release-auditor

AI-powered security auditing of GitHub releases, with automated follow-up
lockfile scanning for 7 days after each audit.

## Overview

When a new release appears in your GitHub notifications, `audit.sh` collects
the evidence — release metadata, the commit diff against the previous release,
contributor history, tag and artifact provenance, OSV advisories — and saves
all lockfiles from the release to disk. Claude Code then analyses that
evidence and writes a structured report: changelog review, diff inspection,
CVE cross-referencing and supply chain provenance.

`audit.sh` can also compare any two versions of a repository directly, which
is useful before upgrading across several releases at once.

`scan-lockfiles.sh` then runs daily (via cron) for 7 days, re-scanning those
lockfiles with `osv-scanner` to catch advisories published after the initial
audit.

```text
GitHub notifications          owner/repo from-ref to-ref
       ↓                                 ↓
  audit.sh  (gh, curl, osv-scanner — deterministic)
     ├── Release metadata, diff, contributors
     ├── Provenance & tag integrity
     ├── OSV advisories
     └── Saves lockfiles to disk
           ↓ evidence.json on stdin
  Claude Code (AGENTS.md, no tools)  →  report
           ↓
  scan-lockfiles.sh  (daily, 7 days)
     └── osv-scanner per lockfile
```

## Security model

The audited content (release notes, commit messages, diffs, lockfiles) is
written by third parties and may contain prompt injection. The tool is built
so that this cannot lead to command execution:

- **Claude has no tools.** It runs with `--restricted --tools ""
  --strict-mcp-config --no-session-persistence` from an empty temp
  directory, with `AGENTS.md` as its system prompt. It only reads the evidence
  bundle and prints text. Your MCP servers, settings and hooks are not loaded.
- **The script does all I/O.** Every network call and file write is done by
  `audit.sh` with fixed commands. Evidence is passed as JSON, so untrusted
  text cannot break out of its field.
- **Strict input validation.** Owner, repository, refs, logins and every
  path derived from them are checked against allow-list patterns
  (`lib.sh`) before use. Lockfile paths from the repository tree are
  validated, symlinks are skipped, and files are staged before being moved
  into `lockfiles/`. `scan-lockfiles.sh` re-validates entries read from
  `seen.json`.
- **Pinned to commits.** Refs are resolved to commit SHAs once; all later API
  calls and lockfile downloads use the SHA, so a tag moved mid-audit cannot
  change what is audited.
- **Deterministic verdict floor.** Facts the script establishes itself (CI
  workflow changes, first-time contributors, target commit not on the
  default branch, OSV advisories, known-malicious packages) set a minimum
  verdict. If Claude reports a lower one, the report gets a `SCRIPT CHECK`
  line — injected text cannot talk the verdict down.
- **Concurrency.** The notification poller holds a lock so overlapping cron
  runs do not start duplicate audits; `seen.json` is updated under a lock
  with an atomic rename. Files are created with `umask 077`.

## Directory structure

```text
release-auditor/
├── AGENTS.md               # Analyst prompt (Claude's system prompt)
├── audit.sh                # Release / version-comparison auditor
├── lib.sh                  # Shared validation, locking and date helpers
├── poll-notifications.sh   # Polls GitHub notifications, calls audit.sh
├── scan-lockfiles.sh       # Daily lockfile scanner (no Claude required)
├── migrate-seen.sh         # One-time migration for pre-v2 seen.json entries
├── state/
│   └── seen.json           # Tracks audited releases and scan windows
├── reports/
│   └── {owner}__{repo}__{tag}/   # Reports saved per release
│       ├── audit-YYYY-MM-DD.txt  # Initial audit report
│       ├── evidence-YYYY-MM-DD.json  # Evidence the report was based on
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
| `osv-scanner` | Lockfile CVE scanning (v2) | `brew install osv-scanner`            |
| `jq`          | JSON processing       | `brew install jq`                          |
| `curl`        | HTTP requests         | pre-installed on macOS                     |

Authenticate before first use:

```bash
gh auth login
export ANTHROPIC_API_KEY=sk-ant-...   # or add to ~/.zshrc
```

## Usage

Every script prints its usage with `-h` or `--help`.

### Audit a single release

```bash
./audit.sh https://github.com/owner/repo/releases/tag/v1.2.3
```

The release is compared against the previous release (or the previous tag if
the repository has no matching release). The report is printed to stdout,
lockfiles are saved to `lockfiles/`, and the release is registered in
`state/seen.json` with a 7-day scan window. Releases already in `seen.json`
are skipped silently.

### Compare two versions

```bash
./audit.sh owner/repo v1.2.0 v1.4.1
```

Audits everything between two refs (tags, branches or commit SHAs) — for
example before upgrading a dependency across several releases. Comparisons
always run, even if audited before. Lockfiles at the `to` ref are saved and
scanned daily for 7 days like a release, under
`lockfiles/owner__repo__v1.2.0...v1.4.1/`.

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
Compared to:   v1.2.2
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

`osv-scanner` v2 parses all of these natively. Lockfiles under
`node_modules/` or `vendor/`, symlinks, and files over 20 MB are not saved.

## Migrating from an older seen.json

If you ran `audit.sh` before lockfile saving was added, your `seen.json`
entries will be plain timestamp strings. Run the migration once:

```bash
./migrate-seen.sh
```

This upgrades all existing entries to the new object format and sets the expiry
to 7 days from the original audit timestamp. Lockfiles already saved to disk
are picked up automatically.

## Customisation

`AGENTS.md` is passed to Claude as its system prompt on every run. Edit it to
adjust the analysis guidance or the report format. What evidence is collected,
which files count as high-signal, which lockfiles are saved and the size
limits are set at the top of `audit.sh`.

To iterate on the prompt without re-collecting evidence, feed a saved
evidence file back in:

```bash
cd "$(mktemp -d)"
claude -p "Write the release audit report for the evidence bundle on stdin." \
  --system-prompt-file /path/to/release-auditor/AGENTS.md \
  --restricted --tools "" --strict-mcp-config --no-session-persistence \
  < /path/to/release-auditor/reports/owner__repo__tag/evidence-YYYY-MM-DD.json
```
