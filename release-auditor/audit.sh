#!/usr/bin/env bash
# audit.sh — security audit of a GitHub release, or of the changes between
# any two versions of a repository.
#
# Usage:
#   audit.sh <github-release-url>
#   audit.sh <owner/repo> <from-ref> <to-ref>
#
# Examples:
#   audit.sh https://github.com/chhoumann/quickadd/releases/tag/2.12.3
#   audit.sh chhoumann/quickadd 2.11.0 2.12.3
#
# The script collects all evidence itself (gh, curl, osv-scanner) and saves
# lockfiles. Claude only reads that evidence: it runs with no tools, no MCP
# servers and no settings, so text planted in a release, commit or diff
# (prompt injection) cannot make it execute anything.

set -euo pipefail

AUDITOR_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
source "$AUDITOR_DIR/lib.sh"

SEEN="$AUDITOR_DIR/state/seen.json"
SEEN_LOCK="$AUDITOR_DIR/state/.seen.lock"
SCAN_DAYS=7

# Limits that keep the evidence bundle (and API usage) bounded.
MAX_PATCH_PER_FILE=20000
MAX_PATCH_TOTAL=400000
MAX_COMMIT_PAGES=10
MAX_AUTHORS=30
MAX_ASSETS=20
MAX_LOCKFILES=50
MAX_LOCKFILE_BYTES=$((20 * 1024 * 1024))
MAX_RELEASE_BODY=20000

HIGH_SIGNAL_RE='^\.github/(workflows|actions)/|(^|/)(package\.json|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|\.yarnrc(\.yml)?|pnpm-lock\.yaml|bun\.lockb?|setup\.py|setup\.cfg|pyproject\.toml|requirements[^/]*\.txt|poetry\.lock|Pipfile(\.lock)?|uv\.lock|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock|build\.rs|composer\.(json|lock)|Gemfile(\.lock)?|[^/]*\.gemspec|mix\.(exs|lock)|pubspec\.(yaml|lock)|Package\.(swift|resolved)|Makefile|Dockerfile[^/]*|[^/]*\.sh|\.npmrc|\.pypirc|\.releaserc[^/]*|CODEOWNERS|\.gitmodules|action\.ya?ml|binding\.gyp)$'
WORKFLOW_RE='^\.github/workflows/'
LOCKFILE_RE='^(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|requirements(-dev|-prod)?\.txt|poetry\.lock|Pipfile\.lock|uv\.lock|go\.sum|Cargo\.lock|composer\.lock|Gemfile\.lock|mix\.lock|pubspec\.lock|Package\.resolved)$'

usage() {
  cat >&2 <<'EOF'
Usage:
  audit.sh <github-release-url>               audit a release against its predecessor
  audit.sh <owner/repo> <from-ref> <to-ref>   audit the changes between two versions

Refs may be tags, branches or commit SHAs.
EOF
  exit 2
}

# ── Argument parsing ─────────────────────────────────────────────────────────

OWNER="" REPO="" FROM_REF="" TO_REF="" MODE=""

parse_release_url() {
  local url="${1%/}" raw_tag
  [[ "$url" =~ ^https://github\.com/([^/?#]+)/([^/?#]+)/releases/tag/([^?#]+)$ ]] \
    || die "Not a GitHub release URL: $url"
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  raw_tag="${BASH_REMATCH[3]}"
  [[ "$raw_tag" =~ ^[A-Za-z0-9._@+/%-]+$ ]] || die "Invalid characters in tag: $raw_tag"
  # Decode %XX escapes (e.g. "pkg%401.0" → "pkg@1.0"); validated again below.
  TO_REF="$(printf '%b' "${raw_tag//\%/\\x}")"
}

case $# in
  1)
    MODE=release
    parse_release_url "$1"
    ;;
  3)
    MODE=compare
    [[ "$1" == */* ]] || usage
    OWNER="${1%%/*}"
    REPO="${1#*/}"
    FROM_REF="$2"
    TO_REF="$3"
    valid_ref "$FROM_REF" || die "Invalid from-ref: $FROM_REF"
    ;;
  *) usage ;;
esac

valid_owner "$OWNER" || die "Invalid owner: $OWNER"
valid_repo "$REPO" || die "Invalid repository: $REPO"
valid_ref "$TO_REF" || die "Invalid ref: $TO_REF"

require_cmds gh jq curl claude osv-scanner

REPO_API="repos/$OWNER/$REPO"
if [[ "$MODE" == release ]]; then
  SEEN_KEY="https://github.com/$OWNER/$REPO/releases/tag/$TO_REF"
else
  SEEN_KEY="https://github.com/$OWNER/$REPO/compare/$FROM_REF...$TO_REF"
fi

mkdir -p "$AUDITOR_DIR/state"
[[ -f "$SEEN" ]] || echo '{}' > "$SEEN"
jq -e 'type == "object"' "$SEEN" > /dev/null || die "Corrupt state file: $SEEN"

# Releases are audited once; explicit comparisons always run.
if [[ "$MODE" == release ]] && jq -e --arg k "$SEEN_KEY" 'has($k)' "$SEEN" > /dev/null; then
  exit 0
fi

WORK="$(mktemp -d)"
HOLDING_SEEN_LOCK=false
cleanup() {
  rm -rf "$WORK"
  if $HOLDING_SEEN_LOCK; then release_lock "$SEEN_LOCK"; fi
}
trap cleanup EXIT

: > "$WORK/notes.txt"

api() {
  gh api "$@" 2>>"$WORK/gh-errors.log"
}

note() {
  printf '%s\n' "$*" >> "$WORK/notes.txt"
}

raw_file() {  # raw_file <repo-path> <commit-sha>
  api -H 'Accept: application/vnd.github.raw' "$REPO_API/contents/${1// /%20}?ref=$2"
}

# ── Ref resolution ───────────────────────────────────────────────────────────
# Every ref is resolved to a commit SHA once; all later calls use the SHA so a
# tag moved during the audit cannot change what is audited.

# resolve_ref <ref> <prefix> → prints commit SHA; writes <prefix>-ref.json
# and, for annotated tags, <prefix>-tag.json.
resolve_ref() {
  local ref="$1" prefix="$WORK/$2" kind="" sha type depth=0
  if api "$REPO_API/git/ref/tags/$ref" > "$prefix-ref.json" \
      && jq -e --arg r "refs/tags/$ref" '.ref == $r' "$prefix-ref.json" > /dev/null; then
    kind=tag
  elif api "$REPO_API/git/ref/heads/$ref" > "$prefix-ref.json" \
      && jq -e --arg r "refs/heads/$ref" '.ref == $r' "$prefix-ref.json" > /dev/null; then
    kind=branch
  elif [[ "$ref" =~ ^[0-9a-fA-F]{7,40}$ ]] \
      && api "$REPO_API/commits/$ref" --jq '{object: {type: "commit", sha: .sha}}' > "$prefix-ref.json"; then
    kind=commit
  else
    return 1
  fi

  sha="$(jq -r '.object.sha' "$prefix-ref.json")"
  type="$(jq -r '.object.type' "$prefix-ref.json")"
  # Annotated tag (possibly a tag of a tag): peel to the commit.
  while [[ "$type" == tag && $depth -lt 3 ]]; do
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    api "$REPO_API/git/tags/$sha" > "$prefix-tag.json" || return 1
    sha="$(jq -r '.object.sha' "$prefix-tag.json")"
    type="$(jq -r '.object.type' "$prefix-tag.json")"
    depth=$((depth + 1))
  done
  [[ "$type" == commit && "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  jq --arg kind "$kind" '. + {kind: $kind}' "$prefix-ref.json" > "$prefix-ref.json.tmp"
  mv "$prefix-ref.json.tmp" "$prefix-ref.json"
  printf '%s' "$sha"
}

api "$REPO_API" > "$WORK/repo.json" || die "Repository not found or not accessible: $OWNER/$REPO"
DEFAULT_BRANCH="$(jq -r '.default_branch' "$WORK/repo.json")"

TO_SHA="$(resolve_ref "$TO_REF" to)" || die "Cannot resolve ref '$TO_REF' in $OWNER/$REPO"

if api "$REPO_API/releases/tags/$(urlencode "$TO_REF")" > "$WORK/release.json"; then
  :
else
  echo 'null' > "$WORK/release.json"
  [[ "$MODE" == release ]] && note "No GitHub release object found for tag $TO_REF"
fi

# ── Base version ─────────────────────────────────────────────────────────────

find_previous_tag() {
  local prev=""
  if api "$REPO_API/releases?per_page=100" > "$WORK/releases.json"; then
    prev="$(jq -r --arg tag "$TO_REF" '
      map(select(.draft | not)) | sort_by(.published_at // .created_at) | reverse
      | (map(.tag_name) | index($tag)) as $i
      | if $i == null then empty else
          .[$i].prerelease as $pre
          | ([.[$i + 1:][] | select($pre or (.prerelease | not))][0].tag_name) // empty
        end' "$WORK/releases.json")"
  fi
  if [[ -z "$prev" ]] && api "$REPO_API/tags?per_page=100" > "$WORK/tags.json"; then
    prev="$(jq -r --arg tag "$TO_REF" '
      map(.name) | index($tag) as $i
      | if $i == null then empty else (.[$i + 1] // empty) end' "$WORK/tags.json")"
  fi
  printf '%s' "$prev"
}

if [[ "$MODE" == release ]]; then
  FROM_REF="$(find_previous_tag)"
  if [[ -n "$FROM_REF" ]] && ! valid_ref "$FROM_REF"; then
    note "Previous tag has unexpected characters and was ignored: $FROM_REF"
    FROM_REF=""
  fi
  [[ -n "$FROM_REF" ]] || note "No previous tag found — first release or unusual tag layout; no diff available"
fi

FROM_SHA=""
if [[ -n "$FROM_REF" ]]; then
  if ! FROM_SHA="$(resolve_ref "$FROM_REF" from)"; then
    [[ "$MODE" == compare ]] && die "Cannot resolve ref '$FROM_REF' in $OWNER/$REPO"
    note "Could not resolve previous tag $FROM_REF"
    FROM_SHA=""
  fi
fi

# ── Commit diff ──────────────────────────────────────────────────────────────

echo '{}' > "$WORK/compare.json"
if [[ -n "$FROM_SHA" ]]; then
  page=1
  : > "$WORK/compare-pages.json"
  while (( page <= MAX_COMMIT_PAGES )); do
    if ! api "$REPO_API/compare/$FROM_SHA...$TO_SHA?per_page=100&page=$page" > "$WORK/page.json"; then
      note "Compare API failed on page $page"
      break
    fi
    cat "$WORK/page.json" >> "$WORK/compare-pages.json"
    (( $(jq '.commits | length' "$WORK/page.json") < 100 )) && break
    page=$((page + 1))
  done
  if [[ -s "$WORK/compare-pages.json" ]]; then
    jq -s '.[0] + {commits: (map(.commits) | add)}' "$WORK/compare-pages.json" > "$WORK/compare.json"
  fi
fi

jq '[.commits // [] | .[] | {
      sha: .sha[0:12],
      author_login: .author.login,
      author_type: .author.type,
      author_name: .commit.author.name,
      committer_login: .committer.login,
      date: .commit.author.date,
      signature_verified: .commit.verification.verified,
      signature_reason: .commit.verification.reason,
      merge: ((.parents | length) > 1),
      message: .commit.message[0:1000]
    }]' "$WORK/compare.json" > "$WORK/commits.json"

jq --arg hs "$HIGH_SIGNAL_RE" --arg wf "$WORKFLOW_RE" \
   --argjson per "$MAX_PATCH_PER_FILE" --argjson total "$MAX_PATCH_TOTAL" '
  [.files // [] | .[] | . + {high_signal: (.filename | test($hs)), workflow: (.filename | test($wf))}]
  | sort_by(if .high_signal then 0 else 1 end)
  | reduce .[] as $f ({out: [], budget: $total};
      ($f.patch // "") as $p
      | ($p[0:$per]) as $p1
      | (if ($p1 | length) > .budget then $p1[0:.budget] else $p1 end) as $p2
      | .budget -= ($p2 | length)
      | .out += [{
          filename: $f.filename,
          previous_filename: $f.previous_filename,
          status: $f.status,
          additions: $f.additions,
          deletions: $f.deletions,
          high_signal: $f.high_signal,
          workflow: $f.workflow,
          patch: $p2,
          patch_truncated: (($p2 | length) < ($p | length)),
          patch_unavailable: ($f.patch == null)
        }])
  | .out' "$WORK/compare.json" > "$WORK/files.json"

# ── Contributors ─────────────────────────────────────────────────────────────
# A human author with no commits reachable from the base version is a
# first-time contributor. GitHub's author filter does not work for app
# accounts, so bots are listed separately.

: > "$WORK/contributors.jsonl"
if [[ -n "$FROM_SHA" ]]; then
  jq -r --argjson max "$MAX_AUTHORS" '
    [.commits // [] | .[] | select(.author.type != "Bot") | .author.login // empty]
    | unique | .[:$max][]' "$WORK/compare.json" \
  | while IFS= read -r login; do
      valid_login "$login" || continue
      prior="$(api "$REPO_API/commits?author=$(urlencode "$login")&sha=$FROM_SHA&per_page=1" --jq 'length')" \
        || prior="error"
      jq -n --arg l "$login" --arg p "$prior" \
        '{login: $l, commits_before_base: (if $p == "error" then null else ($p | tonumber) end)}'
    done > "$WORK/contributors.jsonl"
fi

jq -s --slurpfile c "$WORK/compare.json" '{
    checked: .,
    first_time: [.[] | select(.commits_before_base == 0) | .login],
    bots: ([$c[0].commits // [] | .[] | select(.author.type == "Bot") | .author.login] | unique),
    unlinked_identities: ([$c[0].commits // [] | .[] | select(.author == null) | .commit.author.name] | unique)
  }' "$WORK/contributors.jsonl" > "$WORK/contributors.json"

# ── Provenance ───────────────────────────────────────────────────────────────

ON_DEFAULT_BRANCH="unknown"
if valid_ref "$DEFAULT_BRANCH" \
    && DEFAULT_SHA="$(api "$REPO_API/git/ref/heads/$DEFAULT_BRANCH" --jq '.object.sha')" \
    && [[ "$DEFAULT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  case "$(api "$REPO_API/compare/$DEFAULT_SHA...$TO_SHA" --jq '.status' || true)" in
    behind|identical) ON_DEFAULT_BRANCH="yes" ;;
    ahead|diverged)   ON_DEFAULT_BRANCH="no" ;;
  esac
else
  note "Could not resolve default branch"
fi

api "$REPO_API/git/commits/$TO_SHA" > "$WORK/to-commit.json" || echo '{}' > "$WORK/to-commit.json"
[[ -f "$WORK/to-tag.json" ]] || echo 'null' > "$WORK/to-tag.json"

# Attestations for release assets, looked up by the digest GitHub records.
: > "$WORK/assets.jsonl"
jq -c --argjson max "$MAX_ASSETS" \
  '(. // {}).assets // [] | .[:$max][] | {name, size, digest, uploader: .uploader.login}' \
  "$WORK/release.json" \
| while IFS= read -r asset; do
    digest="$(jq -r '.digest // ""' <<< "$asset")"
    count="null"
    if [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      count="$(api "$REPO_API/attestations/$digest" --jq '.attestations | length' || echo 0)"
      [[ "$count" =~ ^[0-9]+$ ]] || count=0
    fi
    jq -c --argjson n "$count" '. + {attestations: $n}' <<< "$asset"
  done > "$WORK/assets.jsonl"

# ── Lockfiles ────────────────────────────────────────────────────────────────

if [[ "$MODE" == release ]]; then
  ENTRY="${OWNER}__${REPO}__$(safe_name "$TO_REF")"
  LABEL="$OWNER/$REPO @ $TO_REF"
else
  ENTRY="${OWNER}__${REPO}__$(safe_name "$FROM_REF")...$(safe_name "$TO_REF")"
  LABEL="$OWNER/$REPO @ $FROM_REF...$TO_REF"
fi
valid_entry_name "$ENTRY" || die "Cannot build a safe directory name for $LABEL"
LOCKFILE_DIR="lockfiles/$ENTRY"
REPORT_DIR="$AUDITOR_DIR/reports/$ENTRY"
EXPIRES="$(utc_plus_days "$SCAN_DAYS")"

valid_repo_path() {
  [[ "$1" =~ ^[A-Za-z0-9._@+-][A-Za-z0-9._@+/\ -]*$ ]] || return 1
  [[ "/$1/" != */../* && "/$1/" != */./* && "$1" != *//* ]]
}

STAGE="$WORK/lockfiles"
mkdir -p "$STAGE"
: > "$WORK/lockfiles.txt"
if api "$REPO_API/git/trees/$TO_SHA?recursive=1" > "$WORK/tree.json"; then
  jq -e '.truncated' "$WORK/tree.json" > /dev/null && note "Repository tree is truncated; some lockfiles may be missing"
  jq -r --arg re "$LOCKFILE_RE" --argjson maxsize "$MAX_LOCKFILE_BYTES" --argjson max "$MAX_LOCKFILES" '
    [.tree[] | select(.type == "blob" and .mode != "120000" and .size <= $maxsize)
      | select(.path | (split("/") | last | test($re)) and (test("(^|/)(node_modules|vendor)/") | not))
      | .path] | .[:$max][]' "$WORK/tree.json" \
  | while IFS= read -r path; do
      if ! valid_repo_path "$path"; then
        note "Skipped lockfile with unsafe path: $path"
        continue
      fi
      mkdir -p "$STAGE/$(dirname "$path")"
      if raw_file "$path" "$TO_SHA" > "$STAGE/$path"; then
        printf '%s\n' "$path"
      else
        rm -f "$STAGE/$path"
        note "Failed to download lockfile: $path"
      fi
    done > "$WORK/lockfiles.txt"
else
  note "Could not list repository tree; lockfiles not saved"
fi

mkdir -p "$AUDITOR_DIR/lockfiles"
rm -rf "${AUDITOR_DIR:?}/$LOCKFILE_DIR"
mv "$STAGE" "$AUDITOR_DIR/$LOCKFILE_DIR"

: > "$WORK/scanner.jsonl"
while IFS= read -r path; do
  out="$WORK/scan.json"
  rc=0
  osv-scanner scan source --verbosity error --format json -L "$AUDITOR_DIR/$LOCKFILE_DIR/$path" \
    > "$out" 2>>"$WORK/osv-errors.log" || rc=$?
  case $rc in
    0|1)
      jq -c --arg p "$path" '{lockfile: $p, findings: [.results[]?.packages[]?
          | select((.vulnerabilities // []) | length > 0)
          | {name: .package.name, version: .package.version, ecosystem: .package.ecosystem,
             ids: [.vulnerabilities[].id]}]}' "$out" ;;
    128) jq -cn --arg p "$path" '{lockfile: $p, findings: [], note: "no packages found"}' ;;
    *)   jq -cn --arg p "$path" --arg rc "$rc" '{lockfile: $p, error: ("osv-scanner exit code " + $rc)}' ;;
  esac
done < "$WORK/lockfiles.txt" > "$WORK/scanner.jsonl"

# ── OSV advisories for the project itself ────────────────────────────────────

osv_query() {  # JSON request body on stdin
  curl --proto '=https' --tlsv1.2 -sS --fail --max-time 30 \
    -H 'Content-Type: application/json' --data-binary @- \
    https://api.osv.dev/v1/query
}

osv_summary() {
  jq -c '[.vulns // [] | .[] | {id, summary, aliases}]'
}

: > "$WORK/osv.jsonl"
if res="$(jq -n --arg c "$TO_SHA" '{commit: $c}' | osv_query | osv_summary)"; then
  jq -cn --arg c "$TO_SHA" --argjson v "$res" '{query: {commit: $c}, vulns: $v}' >> "$WORK/osv.jsonl"
else
  note "OSV commit query failed"
fi

# Package names declared at the target version, per ecosystem.
pkg_name() {  # pkg_name <ecosystem>
  case "$1" in
    npm)       raw_file package.json "$TO_SHA" | jq -r '.name // empty' ;;
    PyPI)      raw_file pyproject.toml "$TO_SHA" \
                 | awk '/^\[(project|tool\.poetry)\]/{p=1; next} /^\[/{p=0}
                        p && /^name *=/{gsub(/^name *= *["'\'']|["'\''].*$/, ""); print; exit}' ;;
    crates.io) raw_file Cargo.toml "$TO_SHA" \
                 | awk '/^\[package\]/{p=1; next} /^\[/{p=0}
                        p && /^name *=/{gsub(/^name *= *"|".*$/, ""); print; exit}' ;;
    Go)        raw_file go.mod "$TO_SHA" | awk '$1 == "module" {print $2; exit}' ;;
  esac
}

version="${TO_REF##*@}"
for eco_file in npm:package.json PyPI:pyproject.toml crates.io:Cargo.toml Go:go.mod; do
  eco="${eco_file%%:*}"
  jq -e --arg f "${eco_file#*:}" 'any(.tree[]?; .path == $f)' "$WORK/tree.json" > /dev/null 2>&1 || continue
  name="$(pkg_name "$eco" 2>/dev/null || true)"
  [[ "$name" =~ ^[A-Za-z0-9@._/~-]{1,214}$ ]] || continue
  v="$version"
  [[ "$eco" == Go ]] || v="${v#v}"
  if res="$(jq -n --arg n "$name" --arg e "$eco" --arg v "$v" \
      '{package: {name: $n, ecosystem: $e}, version: $v}' | osv_query | osv_summary)"; then
    jq -cn --arg n "$name" --arg e "$eco" --arg v "$v" --argjson r "$res" \
      '{query: {package: $n, ecosystem: $e, version: $v}, vulns: $r}' >> "$WORK/osv.jsonl"
  else
    note "OSV package query failed for $eco/$name"
  fi
done

# ── Deterministic minimum verdict ────────────────────────────────────────────
# Facts the script can establish on its own set a floor that Claude's verdict
# is checked against, so injected text cannot talk the verdict down.

MIN_VERDICT=LOW
REASONS=""
raise() {
  case "$1:$MIN_VERDICT" in
    HIGH:*|MEDIUM:LOW) MIN_VERDICT="$1" ;;
  esac
  REASONS+="${REASONS:+; }$2"
}
jq -e 'any(.[]; .workflow)' "$WORK/files.json" > /dev/null && raise MEDIUM "CI workflow files changed"
jq -e '.first_time | length > 0' "$WORK/contributors.json" > /dev/null && raise MEDIUM "first-time contributor(s)"
[[ "$ON_DEFAULT_BRANCH" == no ]] && raise MEDIUM "target commit is not on the default branch"
jq -se 'any(.[]; .vulns | length > 0)' "$WORK/osv.jsonl" > /dev/null && raise MEDIUM "OSV advisories for this version"
jq -se 'any(.[]; .findings[]?.ids[]? | startswith("MAL-"))' "$WORK/scanner.jsonl" > /dev/null \
  && raise HIGH "known-malicious package in a lockfile"

# ── Evidence bundle ──────────────────────────────────────────────────────────

AUDITED_AT="$(utc_now)"
EVIDENCE="$WORK/evidence.json"
jq -n \
  --arg mode "$MODE" --arg owner "$OWNER" --arg repo "$REPO" \
  --arg base_ref "$FROM_REF" --arg base_sha "$FROM_SHA" \
  --arg target_ref "$TO_REF" --arg target_sha "$TO_SHA" \
  --arg audited_at "$AUDITED_AT" --arg expires "$EXPIRES" \
  --arg lockfile_dir "$LOCKFILE_DIR" --arg on_default "$ON_DEFAULT_BRANCH" \
  --arg min_verdict "$MIN_VERDICT" --arg reasons "$REASONS" \
  --argjson max_body "$MAX_RELEASE_BODY" \
  --slurpfile repo_info "$WORK/repo.json" \
  --slurpfile release "$WORK/release.json" \
  --slurpfile compare "$WORK/compare.json" \
  --slurpfile commits "$WORK/commits.json" \
  --slurpfile files "$WORK/files.json" \
  --slurpfile contributors "$WORK/contributors.json" \
  --slurpfile to_ref "$WORK/to-ref.json" \
  --slurpfile to_tag "$WORK/to-tag.json" \
  --slurpfile to_commit "$WORK/to-commit.json" \
  --slurpfile assets <(jq -s . "$WORK/assets.jsonl") \
  --slurpfile osv <(jq -s . "$WORK/osv.jsonl") \
  --slurpfile scanner <(jq -s . "$WORK/scanner.jsonl") \
  --rawfile lockfiles "$WORK/lockfiles.txt" \
  --rawfile notes "$WORK/notes.txt" '
  def lines: split("\n") | map(select(length > 0));
  {
    audit: {
      mode: $mode, owner: $owner, repo: $repo,
      base_ref: (if $base_ref == "" then null else $base_ref end),
      base_sha: (if $base_sha == "" then null else $base_sha end),
      target_ref: $target_ref, target_sha: $target_sha,
      audited_at: $audited_at, follow_up_scan_until: $expires
    },
    repository: ($repo_info[0] | {full_name, default_branch, archived, fork, created_at, pushed_at}),
    release: ($release[0] | if . == null then null else {
      tag_name, name, draft, prerelease, immutable, created_at, published_at, target_commitish,
      author: {login: .author.login, type: .author.type},
      body: ((.body // "")[0:$max_body]),
      assets: $assets[0]
    } end),
    comparison: ($compare[0] | {
      status, ahead_by, behind_by, total_commits,
      commits_included: (.commits // [] | length),
      files_included: (.files // [] | length),
      file_list_may_be_truncated: ((.files // [] | length) >= 300)
    }),
    commits: $commits[0],
    contributors: $contributors[0],
    high_signal_files: [$files[0][] | select(.high_signal) | .filename],
    workflow_files_changed: [$files[0][] | select(.workflow) | .filename],
    files: $files[0],
    provenance: {
      ref_kind: $to_ref[0].kind,
      annotated_tag: ($to_tag[0] != null),
      tagger: ($to_tag[0] | if . == null then null else .tagger end),
      tag_signature: ($to_tag[0] | if . == null then null else .verification end),
      target_commit: ($to_commit[0] | {author, committer, verification: (.verification | if . == null then null else del(.signature, .payload) end)}),
      target_on_default_branch: $on_default
    },
    osv_advisories: $osv[0],
    lockfiles: {
      saved_to: $lockfile_dir,
      saved: ($lockfiles | lines),
      osv_scanner: $scanner[0]
    },
    deterministic_minimum_verdict: {
      verdict: $min_verdict,
      reasons: ($reasons | split("; ") | map(select(length > 0)))
    },
    collection_notes: ($notes | lines)
  }' > "$EVIDENCE"

# ── Analysis ─────────────────────────────────────────────────────────────────
# No tools, no MCP servers, no user/project settings, no saved session. Run
# from the empty work dir so no project instruction files are picked up.

(
  cd "$WORK"
  claude -p "Write the release audit report for the evidence bundle on stdin." \
    --system-prompt-file "$AUDITOR_DIR/AGENTS.md" \
    --restricted \
    --tools "" \
    --strict-mcp-config \
    --no-session-persistence \
    < "$EVIDENCE" > "$WORK/report.txt"
) || die "Claude analysis failed for $LABEL"

verdict_rank() {
  case "$1" in LOW) echo 1 ;; MEDIUM) echo 2 ;; HIGH) echo 3 ;; *) echo 0 ;; esac
}
VERDICT="$(awk '/^VERDICT:/ { if (match($0, /(LOW|MEDIUM|HIGH)/)) print substr($0, RSTART, RLENGTH); exit }' "$WORK/report.txt")"
if (( $(verdict_rank "$VERDICT") < $(verdict_rank "$MIN_VERDICT") )); then
  printf '\nSCRIPT CHECK: Reported verdict "%s" is below the deterministic minimum %s (%s). Treat this release as %s.\n' \
    "${VERDICT:-missing}" "$MIN_VERDICT" "$REASONS" "$MIN_VERDICT" >> "$WORK/report.txt"
fi

mkdir -p "$REPORT_DIR"
TODAY="$(date -u +%Y-%m-%d)"
REPORT_FILE="$REPORT_DIR/audit-$TODAY.txt"
cp "$WORK/report.txt" "$REPORT_FILE"
cp "$EVIDENCE" "$REPORT_DIR/evidence-$TODAY.json"
cat "$REPORT_FILE"
echo "Report saved: $REPORT_FILE"

# ── State ────────────────────────────────────────────────────────────────────

acquire_lock "$SEEN_LOCK" 60 || die "Timed out waiting for $SEEN_LOCK"
HOLDING_SEEN_LOCK=true
jq \
  --arg key "$SEEN_KEY" \
  --arg ts "$AUDITED_AT" \
  --arg expires "$EXPIRES" \
  --arg lockfile_dir "$LOCKFILE_DIR" \
  --arg owner "$OWNER" \
  --arg repo "$REPO" \
  --arg tag "$TO_REF" \
  --arg base "$FROM_REF" \
  --arg mode "$MODE" \
  --arg label "$LABEL" \
  '. + {($key): {
    "audited_at": $ts,
    "expires": $expires,
    "lockfile_dir": $lockfile_dir,
    "owner": $owner,
    "repo": $repo,
    "tag": $tag,
    "base": $base,
    "mode": $mode,
    "label": $label
  }}' \
  "$SEEN" > "$SEEN.tmp.$$"
mv "$SEEN.tmp.$$" "$SEEN"
release_lock "$SEEN_LOCK"
HOLDING_SEEN_LOCK=false
