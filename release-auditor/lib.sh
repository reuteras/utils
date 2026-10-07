# shellcheck shell=bash
# lib.sh — shared helpers for the release-auditor scripts. Source, don't run.
#
# Everything that ends up in a filesystem path, an API path or a prompt is
# validated here first. Inputs come from command-line arguments, GitHub
# notifications and seen.json, none of which are trusted.

PATH="${PATH}:/home/linuxbrew/.linuxbrew/bin"
umask 077

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmds() {
  local cmd missing=""
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || missing+=" $cmd"
  done
  [[ -z "$missing" ]] || die "Missing required tools:$missing"
}

# ── Validation ───────────────────────────────────────────────────────────────

valid_owner() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]
}

valid_repo() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,100}$ && "$1" != "." && "$1" != ".." ]]
}

# Git refs (tags, branches, SHAs). Deliberately stricter than git itself:
# no "..", "//", leading "-" or "/", trailing "/", or shell/URL metacharacters.
valid_ref() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@+/-]{0,199}$ ]] || return 1
  [[ "$1" != *..* && "$1" != *//* && "$1" != */ ]]
}

# GitHub logins, including app accounts such as "dependabot[bot]".
valid_login() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$ ]]
}

# Directory name under lockfiles/ or reports/. A single segment that starts
# with an alphanumeric and contains no "/" cannot escape its parent.
valid_entry_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]{0,250}$ ]]
}

# Ref → single path segment ("release/1.0" → "release_1.0").
safe_name() {
  printf '%s' "${1//\//_}"
}

# Percent-encode a value for use inside a URL path or query string.
urlencode() {
  jq -rn --arg v "$1" '$v | @uri'
}

# ── Dates ────────────────────────────────────────────────────────────────────

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

utc_plus_days() {
  date -u -d "+$1 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v+"$1"d +%Y-%m-%dT%H:%M:%SZ
}

# ── Locking ──────────────────────────────────────────────────────────────────
# mkdir is atomic on every platform we run on (flock is not available on
# macOS). A lock whose owning process is gone is treated as stale.

# acquire_lock <lockdir> <timeout-seconds>   (timeout 0 = fail immediately)
acquire_lock() {
  local lockdir="$1" timeout="$2" waited=0 pid
  while ! mkdir "$lockdir" 2>/dev/null; do
    pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$lockdir/pid"
      rmdir "$lockdir" 2>/dev/null || true
      continue
    fi
    (( waited >= timeout )) && return 1
    sleep 1
    waited=$((waited + 1))
  done
  echo "$$" > "$lockdir/pid"
}

release_lock() {
  rm -f "$1/pid"
  rmdir "$1" 2>/dev/null || true
}
