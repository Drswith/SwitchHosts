#!/bin/bash
# Tracks the fork-owned copies under crates/swh-core/src/ that derive from
# upstream sources, and reports fork changes outside the fork-owned paths.
# Entries live in crates/upstream-sync.txt. This must stay within bash 3.2
# (macOS /bin/bash): no associative arrays, mapfile or ${var,,}.
set -euo pipefail
# The lists below are word-split and used as globs, so pathname expansion
# must not run on them.
set -f

# Paths this fork owns. The rest of the tree is meant to match upstream, so
# `footprint` reports any change outside this list. Shell globs matched
# against repo-relative paths; `*` also matches across `/`.
FORK_OWNED="macos/* crates/* docs/native-*.md rust-toolchain.toml .gitignore"

die() {
  echo "upstream-sync: $*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
usage: crates/upstream-sync.sh <command> [args]

  check [ref] [-p]        list fork copies whose upstream sources changed since
                          their baseline (ref defaults to upstream/master);
                          -p prints full diffs instead of stats
  bump <fork path> [ref]  make ref (default upstream/master) the new baseline of
                          one fork copy, after its changes have been ported
  footprint [ref]         list changed paths outside the fork-owned allowlist,
                          relative to the merge-base of HEAD and ref

Entries come from crates/upstream-sync.txt; UPSTREAM_SYNC_FILE overrides it.
Exit status: 0 clean, 1 port needed or outside change found, 2 error.
EOF
}

short_sha() {
  git rev-parse --short "$1" 2>/dev/null || printf '%.7s' "$1"
}

is_fork_owned() {
  local pat
  # FORK_OWNED is a list of globs, so it is split and matched unquoted.
  # shellcheck disable=SC2086
  for pat in $FORK_OWNED; do
    # shellcheck disable=SC2254
    case "$1" in $pat) return 0 ;; esac
  done
  return 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
esac

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git worktree"
txt="${UPSTREAM_SYNC_FILE:-$root/crates/upstream-sync.txt}"
# A relative override is made absolute here, before the cd below.
case "$txt" in
  /*) ;;
  *) txt="$PWD/$txt" ;;
esac
# Entries are repo-relative, and `ls-files` prints cwd-relative paths.
cd "$root"

tmp=""
trap 'if [ -n "$tmp" ]; then rm -f "$tmp"; fi' EXIT

# One slot per entry, in parallel arrays.
ent_count=0
ent_line=()
ent_fork=()
ent_base=()
ent_up=()

load_entries() {
  local lineno=0 line fork base i
  [ -f "$txt" ] || die "no such file: $txt"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Whitespace splitting is the format, so $line stays unquoted.
    # shellcheck disable=SC2086
    set -- $line
    [ $# -gt 0 ] || continue
    case "$1" in
      '#'*) continue ;;
    esac
    [ $# -ge 3 ] || die "$txt:$lineno: want <fork path> <baseline sha> <upstream path>..."
    fork=$1
    base=$2
    shift 2
    case "$base" in
      *[!0-9a-f]*) die "$txt:$lineno: baseline is not a hex sha: $base" ;;
    esac
    [ ${#base} -eq 40 ] || die "$txt:$lineno: baseline must be the full 40-char sha: $base"
    i=0
    while [ "$i" -lt "$ent_count" ]; do
      [ "${ent_fork[$i]}" != "$fork" ] || die "$txt:$lineno: $fork is listed twice"
      i=$((i + 1))
    done
    ent_line[$ent_count]=$lineno
    ent_fork[$ent_count]=$fork
    ent_base[$ent_count]=$base
    ent_up[$ent_count]="$*"
    ent_count=$((ent_count + 1))
  done < "$txt"
  [ "$ent_count" -gt 0 ] || die "no entries in $txt"
}

# The upstream path lists are space-separated, so they are deliberately left
# unquoted where they are passed to git.
# shellcheck disable=SC2086
cmd_check() {
  local ref=upstream/master patch=0 ref_sha base_sha fork base ups p rc needs=0 i=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) patch=1 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "check: unknown option $1" ;;
      *) ref=$1 ;;
    esac
    shift
  done
  ref_sha=$(git rev-parse --verify -q "$ref^{commit}") || die "ref does not resolve: $ref"
  load_entries

  while [ "$i" -lt "$ent_count" ]; do
    fork=${ent_fork[$i]}
    base=${ent_base[$i]}
    ups=${ent_up[$i]}
    i=$((i + 1))
    base_sha=$(git rev-parse --verify -q "$base^{commit}") || die "baseline for $fork does not resolve: $base"
    # A typo in an upstream path would make its diff empty and the entry would
    # pass silently, so each path must exist on at least one side.
    for p in $ups; do
      git cat-file -e "$base_sha:$p" 2>/dev/null ||
        git cat-file -e "$ref_sha:$p" 2>/dev/null ||
        die "upstream path for $fork is in neither $base nor $ref: $p"
    done

    rc=0
    git --no-pager diff --no-ext-diff --quiet "$base_sha" "$ref_sha" -- $ups || rc=$?
    case "$rc" in
      0) continue ;;
      1) ;;
      *) die "git diff failed for $fork (exit $rc)" ;;
    esac

    needs=$((needs + 1))
    echo "== $fork"
    echo "   baseline $(short_sha "$base_sha"), upstream $ups"
    if [ "$patch" -eq 1 ]; then
      git --no-pager diff --no-ext-diff "$base_sha" "$ref_sha" -- $ups
    else
      git --no-pager diff --no-ext-diff --stat "$base_sha" "$ref_sha" -- $ups
    fi
    echo
  done

  if [ "$needs" -eq 0 ]; then
    echo "all fork copies are in sync with $ref"
    exit 0
  fi
  echo "$needs of $ent_count fork files need porting"
  exit 1
}

cmd_bump() {
  local fork ref idx=-1 i=0 new old lineno=0 line
  [ $# -ge 1 ] || die "bump: need a fork path"
  [ $# -le 2 ] || die "bump: too many arguments"
  fork=$1
  ref=${2:-upstream/master}
  load_entries
  while [ "$i" -lt "$ent_count" ]; do
    if [ "${ent_fork[$i]}" = "$fork" ]; then
      idx=$i
    fi
    i=$((i + 1))
  done
  [ "$idx" -ge 0 ] || die "not listed in $txt: $fork"
  new=$(git rev-parse --verify -q "$ref^{commit}") || die "ref does not resolve: $ref"
  old=${ent_base[$idx]}
  if [ "$old" = "$new" ]; then
    echo "$fork already at $(short_sha "$new")"
    exit 0
  fi

  tmp=$(mktemp "$txt.XXXXXX")
  # mktemp creates the file 0600; copying the original keeps its mode.
  cp -p "$txt" "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Old and new shas are both 40 characters, so replacing in place keeps the
    # rest of the line, including its column alignment, exactly as it was.
    if [ "$lineno" -eq "${ent_line[$idx]}" ]; then
      line=${line/"$old"/"$new"}
    fi
    printf '%s\n' "$line"
  done < "$txt" > "$tmp"
  mv "$tmp" "$txt"
  tmp=""
  echo "$fork: baseline $(short_sha "$old") -> $(short_sha "$new") ($ref)"
}

cmd_footprint() {
  local ref base files f bad=0
  [ $# -le 1 ] || die "footprint: too many arguments"
  ref=${1:-upstream/master}
  git rev-parse --verify -q "$ref^{commit}" >/dev/null || die "ref does not resolve: $ref"
  base=$(git merge-base HEAD "$ref") || die "no merge-base between HEAD and $ref"
  # Tracked changes against the merge-base (staged or not) plus untracked
  # files. --no-renames keeps the old name of a moved file in the list.
  files=$(
    {
      git -c core.quotepath=off diff --no-renames --name-only "$base" --
      git -c core.quotepath=off ls-files --others --exclude-standard
    } | sort -u
  )
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! is_fork_owned "$f"; then
      if [ "$bad" -eq 0 ]; then
        echo "changes outside fork-owned paths (merge-base with $ref is $(short_sha "$base")):"
      fi
      echo "  $f"
      bad=$((bad + 1))
    fi
  done <<< "$files"
  if [ "$bad" -gt 0 ]; then
    exit 1
  fi
  echo "no changes outside fork-owned paths"
}

cmd=$1
shift
case "$cmd" in
  check) cmd_check "$@" ;;
  bump) cmd_bump "$@" ;;
  footprint) cmd_footprint "$@" ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac
