#!/usr/bin/env bash
# Usage: audit.sh <github-release-url>
# Example: audit.sh https://github.com/chhoumann/quickadd/releases/tag/2.12.3

set -euo pipefail

RELEASE_URL="${1:?Usage: audit.sh <github-release-url>}"
AUDITOR_DIR="$(cd "$(dirname "$0")" && pwd)"
SEEN="$AUDITOR_DIR/state/seen.json"

# Initialize state dir and seen.json if they don't exist
mkdir -p "$AUDITOR_DIR/state"
if [[ ! -f "$SEEN" ]]; then
  echo '{}' > "$SEEN"
fi

# Skip if already audited
if jq -e --arg url "$RELEASE_URL" 'has($url)' "$SEEN" > /dev/null; then
  exit 0
fi

# Parse owner, repo, tag from URL for report naming
# URL format: https://github.com/{owner}/{repo}/releases/tag/{tag}
_url_path="${RELEASE_URL#https://github.com/}"
OWNER="$(echo "$_url_path" | cut -d'/' -f1)"
REPO="$(echo "$_url_path" | cut -d'/' -f2)"
TAG="$(echo "$_url_path" | cut -d'/' -f5)"

REPORT_DIR="$AUDITOR_DIR/reports/${OWNER}__${REPO}__${TAG}"
REPORT_FILE="$REPORT_DIR/audit-$(date -u +%Y-%m-%d).txt"
mkdir -p "$REPORT_DIR"

# Run Claude Code non-interactively from the auditor directory,
# so it picks up CLAUDE.md automatically.
# --allowedTools restricts Claude to read-only + network calls only.
(
  cd "$AUDITOR_DIR"
  claude -p "Audit this release for security issues: $RELEASE_URL" \
    --allowedTools "Bash"
) | tee "$REPORT_FILE"

echo "Report saved: $REPORT_FILE"

# Write full entry to seen.json — expires 7 days from now
_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_expires="$(date -u -d '+7 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v+7d +%Y-%m-%dT%H:%M:%SZ)"
jq \
  --arg url "$RELEASE_URL" \
  --arg ts "$_now" \
  --arg expires "$_expires" \
  --arg lockfile_dir "lockfiles/${OWNER}__${REPO}__${TAG}" \
  --arg owner "$OWNER" \
  --arg repo "$REPO" \
  --arg tag "$TAG" \
  '. + {($url): {
    "audited_at": $ts,
    "expires": $expires,
    "lockfile_dir": $lockfile_dir,
    "owner": $owner,
    "repo": $repo,
    "tag": $tag
  }}' \
  "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
