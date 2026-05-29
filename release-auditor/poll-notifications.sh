#!/usr/bin/env bash
# poll-notifications.sh
# Polls GitHub notifications for release events and audits unseen ones.
# Run via cron: 0 * * * * /path/to/poll-notifications.sh >> /tmp/release-audits.log 2>&1

set -euo pipefail

AUDITOR_DIR="$(cd "$(dirname "$0")" && pwd)"

# Mark notifications as read after fetching so they don't re-trigger
# Remove --jq filter and pipe through jq separately for clarity
gh api notifications?inbox=true \
  --jq '.[] | select(.subject.type == "Release") | .subject.url' \
| while IFS= read -r api_url; do

    # api_url looks like: https://api.github.com/repos/owner/repo/releases/12345678
    # Fetch the tag name from the release ID endpoint
    tag=$(gh api "${api_url#https://api.github.com/}" --jq '.tag_name' 2>/dev/null) || {
      echo "Failed to fetch tag for: $api_url" >&2
      continue
    }

    # Extract owner/repo from the API URL
    repo_path=$(echo "$api_url" \
      | sed 's|https://api.github.com/repos/||' \
      | sed 's|/releases/.*||')

    release_url="https://github.com/${repo_path}/releases/tag/${tag}"

    "$AUDITOR_DIR/audit.sh" "$release_url"

  done
