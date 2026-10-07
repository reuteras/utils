#!/usr/bin/env bash
# poll-notifications.sh
# Polls GitHub notifications for release events and audits unseen ones.
# Run via cron: */10 * * * * /path/to/poll-notifications.sh >> /tmp/release-audits.log 2>&1
#
# Only one poller runs at a time; an audit can take longer than the cron
# interval. audit.sh validates every URL it is given and skips releases that
# are already recorded in state/seen.json.

set -euo pipefail

AUDITOR_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
source "$AUDITOR_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: poll-notifications.sh [-h | --help]

Reads your unread GitHub notifications and runs audit.sh for every release
notification that has not been audited yet (see state/seen.json). Only one
poller runs at a time; a run that finds another still active exits silently.
Exits non-zero if any audit failed.

Cron example (every 10 minutes):
  */10 * * * * /path/to/release-auditor/poll-notifications.sh

Requires: gh (authenticated), jq, plus everything audit.sh needs.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

require_cmds gh jq

POLL_LOCK="$AUDITOR_DIR/state/.poll.lock"
mkdir -p "$AUDITOR_DIR/state"
acquire_lock "$POLL_LOCK" 0 || exit 0   # previous poll still running
trap 'release_lock "$POLL_LOCK"' EXIT

failed=0

while IFS= read -r api_url; do
  # api_url looks like: https://api.github.com/repos/owner/repo/releases/12345678
  path="${api_url#https://api.github.com/}"
  if [[ ! "$path" =~ ^repos/([^/]+)/([^/]+)/releases/[0-9]+$ ]] \
      || ! valid_owner "${BASH_REMATCH[1]}" || ! valid_repo "${BASH_REMATCH[2]}"; then
    echo "Skipping unexpected notification URL: $api_url" >&2
    continue
  fi

  html_url="$(gh api "$path" --jq '.html_url' 2>/dev/null)" || {
    echo "Failed to fetch release: $api_url" >&2
    continue
  }

  "$AUDITOR_DIR/audit.sh" "$html_url" || {
    echo "Audit failed: $html_url" >&2
    failed=$((failed + 1))
  }
done < <(gh api --paginate notifications \
  --jq '.[] | select(.subject.type == "Release") | .subject.url // empty')

(( failed == 0 ))
