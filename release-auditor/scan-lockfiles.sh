#!/usr/bin/env bash
# scan-lockfiles.sh
#
# Runs daily (via cron) for up to 7 days after a release audit.
# Checks all saved lockfiles against OSV for new CVEs and known-malicious
# packages. No Claude required — pure osv-scanner + OSV API.
#
# Cron example (daily at 07:00):
#   0 7 * * * /path/to/release-auditor/scan-lockfiles.sh >> /tmp/lockfile-scans.log 2>&1

set -euo pipefail

AUDITOR_DIR="$(cd "$(dirname "$0")" && pwd)"
SEEN="$AUDITOR_DIR/state/seen.json"
TODAY="$(date -u +%Y-%m-%d)"
PATH="${PATH}:/home/linuxbrew/.linuxbrew/bin"

# ── Dependency checks ────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  for cmd in jq curl osv-scanner; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required tools: ${missing[*]}"
    echo "Install: brew install jq osv-scanner && brew install curl"
    exit 1
  fi
}

# ── OSV batch query for a single package ─────────────────────────────────────
# Used as fallback when osv-scanner doesn't support a lockfile format directly.

query_osv_package() {
  local name="$1" version="$2" ecosystem="$3"
  curl -sf https://api.osv.dev/v1/query \
    -H 'Content-Type: application/json' \
    -d "{\"package\":{\"name\":\"${name}\",\"ecosystem\":\"${ecosystem}\"},\"version\":\"${version}\"}" \
  | jq -r '.vulns[]?.id // empty' 2>/dev/null || true
}

# ── Lockfile scanner ──────────────────────────────────────────────────────────

scan_lockfile() {
  local lockfile="$1"
  local filename
  filename="$(basename "$lockfile")"

  # Manifest files — not lockfiles, skip silently
  local manifests=(
    "package.json"
    "go.mod"
    "pyproject.toml"
    "Cargo.toml"
    "setup.py"
    "setup.cfg"
  )
  for m in "${manifests[@]}"; do
    [[ "$filename" == "$m" ]] && return 0
  done

  # osv-scanner supports these lockfile formats natively
  local osv_supported=(
    "package-lock.json"
    "yarn.lock"
    "pnpm-lock.yaml"
    "requirements.txt"
    "requirements-dev.txt"
    "requirements-prod.txt"
    "poetry.lock"
    "Pipfile.lock"
    "go.sum"
    "Cargo.lock"
    "composer.lock"
    "Gemfile.lock"
    "pubspec.lock"
  )

  local supported=false
  for name in "${osv_supported[@]}"; do
    [[ "$filename" == "$name" ]] && supported=true && break
  done

  if $supported; then
    local output exit_code=0
    output=$(osv-scanner --lockfile "$lockfile" --format table 2>&1) || exit_code=$?
    case $exit_code in
      0) ;;                              # clean — print nothing
      1) echo "$output" ;;              # vulnerabilities found
      *) echo "SCAN_ERROR: $output" ;;  # parse or tool failure
    esac
  else
    # Fallback: parse the lockfile manually and query OSV per package.
    # Currently handles: uv.lock, mix.lock, Package.resolved
    fallback_scan "$lockfile"
  fi
}

# ── Fallback scanner for formats osv-scanner doesn't support ─────────────────

fallback_scan() {
  local lockfile="$1"
  local filename
  filename="$(basename "$lockfile")"
  local output=""

  case "$filename" in
    uv.lock)
      # uv.lock is TOML; extract name+version pairs
      local results
      results=$(grep -E '^name = |^version = ' "$lockfile" \
        | paste - - \
        | sed 's/name = "\(.*\)"\s*version = "\(.*\)"/\1 \2/' \
        | while read -r name version; do
            ids=$(query_osv_package "$name" "$version" "PyPI")
            [[ -n "$ids" ]] && echo "  $name@$version: $ids"
          done)
      [[ -n "$results" ]] && output="uv.lock findings:\n$results"
      ;;

    mix.lock)
      # Elixir mix.lock: {:package, "version", ...}
      local results
      results=$(grep -oE ':\w+, "[^"]+"' "$lockfile" \
        | sed 's/:\(.*\), "\(.*\)"/\1 \2/' \
        | while read -r name version; do
            ids=$(query_osv_package "$name" "$version" "Hex")
            [[ -n "$ids" ]] && echo "  $name@$version: $ids"
          done)
      [[ -n "$results" ]] && output="mix.lock findings:\n$results"
      ;;

    Package.resolved)
      # Swift Package.resolved v2/v3 JSON
      local results
      results=$(jq -r '.pins[]? | "\(.identity) \(.state.version // .state.revision // "unknown")"' \
        "$lockfile" 2>/dev/null \
        | while read -r name version; do
            ids=$(query_osv_package "$name" "$version" "SwiftURL")
            [[ -n "$ids" ]] && echo "  $name@$version: $ids"
          done)
      [[ -n "$results" ]] && output="Package.resolved findings:\n$results"
      ;;

    *)
      ;;
  esac

  echo -e "$output"
}

# ── Report printer ────────────────────────────────────────────────────────────

print_report() {
  local owner="$1" repo="$2" tag="$3" lockfile_dir="$4" expires="$5"
  local has_findings=false has_errors=false

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "LOCKFILE SCAN: ${owner}/${repo} @ ${tag}"
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
      echo "${findings#SCAN_ERROR: }" | sed 's/^/    /'
    else
      has_findings=true
      echo "  Result:   VULNERABILITIES FOUND"
      echo ""
      echo "$findings" | sed 's/^/    /'
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
  check_deps

  if [[ ! -f "$SEEN" ]]; then
    echo "No seen.json found at $SEEN — nothing to scan."
    exit 0
  fi

  local active=0

  # Iterate over all entries in seen.json that have an expires field
  while IFS= read -r url; do
    local entry
    entry=$(jq -r --arg url "$url" '.[$url]' "$SEEN")

    # Skip legacy string entries (old format without expiry)
    if ! echo "$entry" | jq -e '.expires' &>/dev/null 2>&1; then
      continue
    fi

    local expires owner repo tag lockfile_dir
    expires=$(echo "$entry"     | jq -r '.expires')
    owner=$(echo "$entry"       | jq -r '.owner')
    repo=$(echo "$entry"        | jq -r '.repo')
    tag=$(echo "$entry"         | jq -r '.tag')
    lockfile_dir=$(echo "$entry" | jq -r '.lockfile_dir')

    # Skip if the 7-day window has passed
    if [[ "$TODAY" > "${expires:0:10}" ]]; then
      continue
    fi

    active=$((active + 1))
    REPORT_DIR="$AUDITOR_DIR/reports/${owner}__${repo}__${tag}"
    REPORT_FILE="$REPORT_DIR/scan-${TODAY}.txt"
    mkdir -p "$REPORT_DIR"

    local tmp
    tmp="$(mktemp)"
    print_report "$owner" "$repo" "$tag" "$lockfile_dir" "${expires:0:10}" > "$tmp"

    # Compare against today's report if it already exists (same-day re-runs),
    # otherwise against the most recent previous day's report.
    local prev
    if [[ -f "$REPORT_FILE" ]]; then
      prev="$REPORT_FILE"
    else
      prev="$(find "$REPORT_DIR" -name "scan-*.txt" 2>/dev/null | sort | tail -1)"
    fi

    # Print to stdout (triggering cron email) only if content changed.
    # Exclude the "Scan date:" line since it changes every day.
    if [[ -z "$prev" ]] || \
       ! diff <(grep -v '^Scan date:' "$prev") \
              <(grep -v '^Scan date:' "$tmp") > /dev/null 2>&1; then
      cat "$tmp"
      echo "Report saved: $REPORT_FILE"
    fi

    mv "$tmp" "$REPORT_FILE"

  done < <(jq -r 'keys[]' "$SEEN")

  return 0
}

main "$@"
