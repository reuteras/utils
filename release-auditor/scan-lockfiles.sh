#!/usr/bin/env bash
# scan-lockfiles.sh
#
# Runs daily (via cron) for up to 7 days after a release audit.
# Checks all saved lockfiles against OSV for new CVEs and known-malicious
# packages. No Claude required — pure osv-scanner.
#
# Cron example (daily at 07:00):
#   0 7 * * * /path/to/release-auditor/scan-lockfiles.sh >> /tmp/lockfile-scans.log 2>&1

set -euo pipefail

AUDITOR_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
source "$AUDITOR_DIR/lib.sh"

SEEN="$AUDITOR_DIR/state/seen.json"
TODAY="$(date -u +%Y-%m-%d)"
LOCKFILE_RE='^(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|requirements(-dev|-prod)?\.txt|poetry\.lock|Pipfile\.lock|uv\.lock|go\.sum|Cargo\.lock|composer\.lock|Gemfile\.lock|mix\.lock|pubspec\.lock|Package\.resolved)$'

# ── Lockfile scanner ──────────────────────────────────────────────────────────
# osv-scanner (v2) parses every supported lockfile format natively, including
# uv.lock, mix.lock and Package.resolved.

scan_lockfile() {
  local lockfile="$1" output exit_code=0

  # Only scan files audit.sh would have saved; ignore anything else.
  [[ "$(basename "$lockfile")" =~ $LOCKFILE_RE ]] || return 0

  output=$(osv-scanner scan source --verbosity error --format table -L "$lockfile" 2>&1) \
    || exit_code=$?
  case $exit_code in
    0|128) ;;                                     # clean / no packages
    1) printf '%s\n' "$output" ;;                 # vulnerabilities found
    *) printf 'SCAN_ERROR: %s\n' "$output" ;;     # parse or tool failure
  esac
}

# ── Report printer ────────────────────────────────────────────────────────────

print_report() {
  local label="$1" lockfile_dir="$2" expires="$3"
  local has_findings=false has_errors=false

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "LOCKFILE SCAN: ${label}"
  echo "Scan date:     ${TODAY}    Monitoring until: ${expires}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local full_lockfile_dir="$AUDITOR_DIR/$lockfile_dir"

  if [[ ! -d "$full_lockfile_dir" ]]; then
    echo "  ERROR: Lockfile directory not found: $full_lockfile_dir"
    echo ""
    return
  fi

  # Find all lockfiles recursively
  local lockfiles=()
  while IFS= read -r -d '' f; do
    lockfiles+=("$f")
  done < <(find "$full_lockfile_dir" -type f -print0)

  if [[ ${#lockfiles[@]} -eq 0 ]]; then
    echo "  No lockfiles found in $lockfile_dir"
    echo ""
    return
  fi

  for lockfile in "${lockfiles[@]}"; do
    local rel_path="${lockfile#"$full_lockfile_dir/"}"
    echo ""
    echo "  Lockfile: $rel_path"

    local findings
    findings=$(scan_lockfile "$lockfile")

    if [[ -z "$findings" || "$findings" =~ ^[[:space:]]*$ ]]; then
      echo "  Result:   No vulnerabilities found"
    elif [[ "$findings" == SCAN_ERROR:* ]]; then
      has_errors=true
      echo "  Result:   SCAN ERROR"
      echo ""
      while IFS= read -r _ln; do echo "    $_ln"; done <<< "${findings#SCAN_ERROR: }"
    else
      has_findings=true
      echo "  Result:   VULNERABILITIES FOUND"
      echo ""
      while IFS= read -r _ln; do echo "    $_ln"; done <<< "$findings"
    fi
  done

  echo ""
  if $has_findings; then
    echo "  VERDICT: FINDINGS DETECTED — review above"
  elif $has_errors; then
    echo "  VERDICT: SCAN ERROR — check tool compatibility"
  else
    echo "  VERDICT: CLEAN"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  require_cmds jq osv-scanner

  if [[ ! -f "$SEEN" ]]; then
    echo "No seen.json found at $SEEN — nothing to scan."
    exit 0
  fi

  local active=0

  # One line per entry with an expiry: expires <TAB> lockfile_dir <TAB> label.
  # Legacy string entries (old format without expiry) are skipped.
  while IFS=$'\t' read -r expires lockfile_dir label; do
    local entry_name="${lockfile_dir#lockfiles/}"

    # seen.json is not trusted: the directory must be a single safe segment
    # under lockfiles/, and the expiry must look like a date.
    if [[ "$lockfile_dir" != lockfiles/* ]] || ! valid_entry_name "$entry_name" \
        || [[ ! "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
      echo "WARNING: Skipping malformed seen.json entry: $label" >&2
      continue
    fi
    label="$(printf '%s' "$label" | tr -d '[:cntrl:]')"

    # Skip if the 7-day window has passed
    if [[ "$TODAY" > "${expires:0:10}" ]]; then
      continue
    fi

    active=$((active + 1))
    REPORT_DIR="$AUDITOR_DIR/reports/$entry_name"
    REPORT_FILE="$REPORT_DIR/scan-${TODAY}.txt"
    mkdir -p "$REPORT_DIR"

    local tmp
    tmp="$(mktemp)"
    print_report "$label" "$lockfile_dir" "${expires:0:10}" > "$tmp"

    # Find comparison baseline:
    # - Same-day re-run: compare against today's existing file
    # - First run of the day: compare against most recent previous scan
    local prev prev_date=""
    if [[ -f "$REPORT_FILE" ]]; then
      prev="$REPORT_FILE"
    else
      prev="$(find "$REPORT_DIR" -name "scan-*.txt" 2>/dev/null | sort | tail -1)"
      if [[ -n "$prev" ]]; then
        local prev_base
        prev_base="$(basename "$prev")"
        prev_date="${prev_base#scan-}"
        prev_date="${prev_date%.txt}"
      fi
    fi

    if [[ -z "$prev" ]]; then
      # First ever scan for this release — show full report
      cat "$tmp"
      echo "Report saved: $REPORT_FILE"
    else
      # Show only what changed since the last scan (excluding the date line)
      local diff_out
      diff_out=$(diff \
        <(grep -v '^Scan date:' "$prev") \
        <(grep -v '^Scan date:' "$tmp") || true)

      if [[ -n "$diff_out" ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "LOCKFILE SCAN CHANGES: ${label}"
        local date_line="Scan date:     ${TODAY}"
        [[ -n "$prev_date" ]] && date_line+="    Changed since: ${prev_date}"
        echo "$date_line"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        while IFS= read -r _ln; do
          case "$_ln" in
            '> '*) echo "  + ${_ln:2}" ;;
            '< '*) echo "  - ${_ln:2}" ;;
          esac
        done <<< "$diff_out"
        echo ""
        echo "Report saved: $REPORT_FILE"
      fi
    fi

    mv "$tmp" "$REPORT_FILE"

  done < <(jq -r 'to_entries[] | select(.value | type == "object" and has("expires"))
    | .value | [.expires, .lockfile_dir,
                (.label // "\(.owner)/\(.repo) @ \(.tag)")] | @tsv' "$SEEN")

  return 0
}

usage() {
  cat <<'EOF'
Usage: scan-lockfiles.sh [-h | --help]

Scans the lockfiles saved by audit.sh with osv-scanner, for every release or
comparison in state/seen.json whose 7-day follow-up window has not expired.

The first scan of a release prints the full report; later scans print only
what changed since the previous scan, so the script is silent when nothing
is new. Reports are always saved to reports/<entry>/scan-YYYY-MM-DD.txt.

Cron example (daily at 07:00):
  0 7 * * * /path/to/release-auditor/scan-lockfiles.sh

Requires: jq, osv-scanner (v2).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

main "$@"
