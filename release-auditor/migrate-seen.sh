#!/usr/bin/env bash
# migrate-seen.sh
#
# One-time migration of seen.json string entries to the new object format.
# Safe to run multiple times — skips entries already in object format.
# Infers lockfile_dir from the lockfiles/ directory on disk.

set -euo pipefail

AUDITOR_DIR="$(cd "$(dirname "$0")" && pwd)"
SEEN="$AUDITOR_DIR/state/seen.json"

if [[ ! -f "$SEEN" ]]; then
  echo "No seen.json found at $SEEN — nothing to migrate."
  exit 0
fi

updated=0
skipped=0

new_json=$(jq 'to_entries | map(
  if (.value | type) == "string" then
    # Parse owner, repo, tag from URL
    # URL format: https://github.com/{owner}/{repo}/releases/tag/{tag}
    (.key | split("/")) as $parts |
    {
      key: .key,
      value: {
        audited_at: .value,
        expires:    "",        # filled in below by bash
        owner:      $parts[3],
        repo:       $parts[4],
        tag:        $parts[7],
        lockfile_dir: ("lockfiles/" + $parts[3] + "__" + $parts[4] + "__" + $parts[7])
      }
    }
  else
    .
  end
) | from_entries' "$SEEN")

# Now fill in expires for any entry that has an empty expires,
# using audited_at + 7 days
while IFS= read -r url; do
  entry=$(echo "$new_json" | jq -r --arg url "$url" '.[$url]')
  expires=$(echo "$entry" | jq -r '.expires')

  if [[ "$expires" == "" ]]; then
    audited_at=$(echo "$entry" | jq -r '.audited_at')

    # BSD date (macOS) vs GNU date (Linux)
    if date --version &>/dev/null 2>&1; then
      new_expires=$(date -u -d "$audited_at + 7 days" +%Y-%m-%dT%H:%M:%SZ)
    else
      new_expires=$(date -u -v+7d -j -f "%Y-%m-%dT%H:%M:%SZ" "$audited_at" +%Y-%m-%dT%H:%M:%SZ)
    fi

    new_json=$(echo "$new_json" | jq \
      --arg url "$url" \
      --arg exp "$new_expires" \
      '.[$url].expires = $exp')

    owner=$(echo "$entry" | jq -r '.owner')
    repo=$(echo "$entry"  | jq -r '.repo')
    tag=$(echo "$entry"   | jq -r '.tag')
    echo "  Migrated: $owner/$repo @ $tag (expires ${new_expires:0:10})"
    updated=$((updated + 1))
  else
    skipped=$((skipped + 1))
  fi

done < <(echo "$new_json" | jq -r 'keys[]')

echo "$new_json" > "$SEEN"
echo ""
echo "Done. Migrated: $updated  Already up-to-date: $skipped"
