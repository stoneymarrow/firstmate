#!/usr/bin/env bash
# fm-upstream-sync.sh - prepare and maintain a review-only fork sync PR.
#
# The prepare command fetches the fork and its upstream, then updates one
# automation-owned branch on the fork. A clean upstream commit delta is
# represented by an explicit merge commit whose first parent is the fork base
# and whose second parent is the upstream head. Fork-only AGENTS.md drift is
# represented by a one-parent correction commit. If git reports conflicts, the
# branch carries the upstream tree plus an empty managed marker commit so GitHub
# can expose the conflict against the fork base for human resolution. AGENTS.md
# always comes from upstream, and tracked fleet-private paths are refused.
#
# The upsert-pr command opens one PR or refreshes the existing open PR for the
# automation branch. It never enables auto-merge and never merges a PR.
#
# Required setup for prepare:
#   - origin (or FM_SYNC_ORIGIN_REMOTE) is the writable fork remote.
#   - upstream (or FM_SYNC_UPSTREAM_REMOTE) is the fetch source.
#
# Environment overrides:
#   FM_SYNC_ORIGIN_REMOTE       writable fork remote (default: origin)
#   FM_SYNC_UPSTREAM_REMOTE     fetch-only source remote (default: upstream)
#   FM_SYNC_BASE_BRANCH         fork PR base branch (default: main)
#   FM_SYNC_UPSTREAM_BRANCH     upstream source branch (default: main)
#   FM_SYNC_BRANCH              fork automation branch
#                               (default: automation/upstream-sync)
#   FM_SYNC_OUTPUT              key=value output file (default: GITHUB_OUTPUT)
#
# upsert-pr additionally requires FM_SYNC_REPOSITORY, FM_SYNC_BASE_SHA,
# FM_SYNC_UPSTREAM_SHA, FM_SYNC_UPSTREAM_REPOSITORY, and FM_SYNC_MODE. It
# accepts FM_SYNC_CONFLICT=true|false and requires an authenticated gh CLI.
#
# Usage:
#   fm-upstream-sync.sh prepare
#   fm-upstream-sync.sh upsert-pr
#   fm-upstream-sync.sh --help
set -eu

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-upstream-sync.sh: %s\n' "$1" >&2
  exit 1
}

write_output() {
  key=$1
  value=$2
  output=${FM_SYNC_OUTPUT:-${GITHUB_OUTPUT:-}}
  if [ -n "$output" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$output"
  else
    printf '%s=%s\n' "$key" "$value"
  fi
}

validate_branch() {
  git check-ref-format --branch "$1" >/dev/null 2>&1 || die "invalid branch name: $1"
}

assert_no_private_paths() {
  treeish=$1
  tracked=$(git ls-tree -r --name-only "$treeish" -- \
    data state config projects .no-mistakes)
  if [ -n "$tracked" ]; then
    printf 'fm-upstream-sync.sh: refusing tracked fleet-private paths:\n%s\n' "$tracked" >&2
    exit 1
  fi
}

trailer_value() {
  commit=$1
  key=$2
  git show -s --format=%B "$commit" | sed -n "s/^${key}:[[:space:]]*//p" | tail -1
}

commit_managed_marker() {
  subject=$1
  conflict=$2
  mode=$3
  allow_empty=${4:-false}
  set -- git -c user.name='Firstmate upstream sync' \
    -c user.email='actions@users.noreply.github.com' commit
  if [ "$allow_empty" = true ]; then
    set -- "$@" --allow-empty
  fi
  "$@" -m "$subject" -m "Automated review branch; never merge without human approval.

Upstream-Sync-Managed: true
Upstream-Sync-Base: $base_sha
Upstream-Sync-Head: $upstream_sha
Upstream-Sync-Conflict: $conflict
Upstream-Sync-Mode: $mode"
}

prepare() {
  origin_remote=${FM_SYNC_ORIGIN_REMOTE:-origin}
  upstream_remote=${FM_SYNC_UPSTREAM_REMOTE:-upstream}
  base_branch=${FM_SYNC_BASE_BRANCH:-main}
  upstream_branch=${FM_SYNC_UPSTREAM_BRANCH:-main}
  sync_branch=${FM_SYNC_BRANCH:-automation/upstream-sync}

  [ "$origin_remote" != "$upstream_remote" ] || die "origin and upstream remotes must differ"
  [ "$sync_branch" != "$base_branch" ] || die "sync branch must not be the fork base branch"
  validate_branch "$base_branch"
  validate_branch "$upstream_branch"
  validate_branch "$sync_branch"
  git rev-parse --show-toplevel >/dev/null 2>&1 || die "not inside a git worktree"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "worktree must be clean"
  fi
  git remote get-url "$origin_remote" >/dev/null 2>&1 || die "missing fork remote: $origin_remote"
  git remote get-url "$upstream_remote" >/dev/null 2>&1 || die "missing upstream remote: $upstream_remote"

  origin_url=$(git remote get-url "$origin_remote")
  upstream_url=$(git remote get-url "$upstream_remote")
  [ "$origin_url" != "$upstream_url" ] || die "fork and upstream fetch URLs must differ"

  # Defense in depth: even a later accidental push naming this remote cannot
  # reach upstream. The only push below names origin_remote explicitly.
  git remote set-url --push "$upstream_remote" DISABLED

  git fetch --no-tags "$origin_remote" \
    "+refs/heads/$base_branch:refs/remotes/$origin_remote/$base_branch"
  git fetch --no-tags "$upstream_remote" \
    "+refs/heads/$upstream_branch:refs/remotes/$upstream_remote/$upstream_branch"

  base_sha=$(git rev-parse "refs/remotes/$origin_remote/$base_branch")
  upstream_sha=$(git rev-parse "refs/remotes/$upstream_remote/$upstream_branch")
  git merge-base "$base_sha" "$upstream_sha" >/dev/null 2>&1 || \
    die "fork and upstream branches do not share history"
  git cat-file -e "$upstream_sha:AGENTS.md" 2>/dev/null || \
    die "upstream AGENTS.md is missing"
  assert_no_private_paths "$base_sha"
  assert_no_private_paths "$upstream_sha"

  agents_match=true
  if ! git diff --quiet "$base_sha" "$upstream_sha" -- AGENTS.md; then
    agents_match=false
  fi

  write_output base_sha "$base_sha"
  write_output upstream_sha "$upstream_sha"
  write_output branch "$sync_branch"

  upstream_is_ancestor=false
  if git merge-base --is-ancestor "$upstream_sha" "$base_sha"; then
    upstream_is_ancestor=true
  fi
  if [ "$upstream_is_ancestor" = true ] && [ "$agents_match" = true ]; then
    write_output has_delta false
    write_output branch_updated false
    write_output conflict false
    write_output mode none
    printf 'upstream-sync: no upstream delta\n'
    return 0
  fi

  existing_sha=
  if git ls-remote --exit-code --heads "$origin_remote" \
      "refs/heads/$sync_branch" >/dev/null 2>&1; then
    git fetch --no-tags "$origin_remote" \
      "+refs/heads/$sync_branch:refs/remotes/$origin_remote/$sync_branch"
    existing_sha=$(git rev-parse "refs/remotes/$origin_remote/$sync_branch")
    managed=$(trailer_value "$existing_sha" Upstream-Sync-Managed)
    [ "$managed" = true ] || \
      die "refusing to overwrite non-managed fork branch: $sync_branch"
    existing_base=$(trailer_value "$existing_sha" Upstream-Sync-Base)
    existing_upstream=$(trailer_value "$existing_sha" Upstream-Sync-Head)
    existing_conflict=$(trailer_value "$existing_sha" Upstream-Sync-Conflict)
    existing_mode=$(trailer_value "$existing_sha" Upstream-Sync-Mode)
    assert_no_private_paths "$existing_sha"
    existing_agents_match=true
    if ! git diff --quiet "$existing_sha" "$upstream_sha" -- AGENTS.md; then
      existing_agents_match=false
    fi
    existing_mode_valid=false
    case "$existing_mode:$existing_conflict:$upstream_is_ancestor" in
      agents-correction:false:true|merge:false:false|conflict:true:false)
        existing_mode_valid=true
        ;;
    esac
    if [ "$existing_base" = "$base_sha" ] && \
        [ "$existing_upstream" = "$upstream_sha" ] && \
        [ "$existing_agents_match" = true ] && \
        [ "$existing_mode_valid" = true ]; then
      write_output has_delta true
      write_output branch_updated false
      write_output conflict "${existing_conflict:-false}"
      write_output mode "$existing_mode"
      printf 'upstream-sync: branch already represents current fork and upstream heads\n'
      return 0
    fi
  fi

  git checkout --detach "$base_sha"
  conflict=false
  if [ "$upstream_is_ancestor" = true ]; then
    mode=agents-correction
    git checkout "$upstream_sha" -- AGENTS.md
    git diff --quiet "$upstream_sha" -- AGENTS.md || \
      die "generated branch did not retain upstream AGENTS.md"
    commit_managed_marker 'chore: restore upstream AGENTS.md' false "$mode"
  elif git -c user.name='Firstmate upstream sync' \
      -c user.email='actions@users.noreply.github.com' \
      merge --no-ff --no-commit "$upstream_sha"; then
    mode=merge
    git checkout "$upstream_sha" -- AGENTS.md
    git diff --quiet "$upstream_sha" -- AGENTS.md || \
      die "generated branch did not retain upstream AGENTS.md"
    commit_managed_marker 'chore: sync fork with upstream' false "$mode"
  else
    if [ -z "$(git ls-files -u)" ]; then
      git merge --abort >/dev/null 2>&1 || true
      die "upstream merge failed without reviewable conflicts"
    fi
    conflict=true
    mode=conflict
    git merge --abort
    git checkout --detach "$upstream_sha"
    commit_managed_marker 'chore: stage conflicting upstream sync for review' true "$mode" true
  fi

  generated_sha=$(git rev-parse HEAD)
  if [ -n "$existing_sha" ]; then
    git push --force-with-lease="refs/heads/$sync_branch:$existing_sha" \
      "$origin_remote" "HEAD:refs/heads/$sync_branch"
  else
    git push "$origin_remote" "HEAD:refs/heads/$sync_branch"
  fi

  write_output has_delta true
  write_output branch_updated true
  write_output conflict "$conflict"
  write_output mode "$mode"
  write_output generated_sha "$generated_sha"
  printf 'upstream-sync: fork branch %s updated (conflict=%s)\n' "$sync_branch" "$conflict"
}

upsert_pr() {
  command -v gh >/dev/null 2>&1 || die "gh is required to open or refresh the sync PR"
  repository=${FM_SYNC_REPOSITORY:-${GITHUB_REPOSITORY:-}}
  base_branch=${FM_SYNC_BASE_BRANCH:-main}
  sync_branch=${FM_SYNC_BRANCH:-automation/upstream-sync}
  base_sha=${FM_SYNC_BASE_SHA:-}
  upstream_sha=${FM_SYNC_UPSTREAM_SHA:-}
  upstream_repository=${FM_SYNC_UPSTREAM_REPOSITORY:-}
  conflict=${FM_SYNC_CONFLICT:-false}
  mode=${FM_SYNC_MODE:-}

  [ -n "$repository" ] || die "FM_SYNC_REPOSITORY is required"
  [ -n "$base_sha" ] || die "FM_SYNC_BASE_SHA is required"
  [ -n "$upstream_sha" ] || die "FM_SYNC_UPSTREAM_SHA is required"
  [ -n "$upstream_repository" ] || die "FM_SYNC_UPSTREAM_REPOSITORY is required"
  [ -n "$mode" ] || die "FM_SYNC_MODE is required"
  case "$repository" in
    */*) repository_owner=${repository%%/*} ;;
    *) die "FM_SYNC_REPOSITORY must be owner/name" ;;
  esac
  case "$repository_owner" in
    ''|*[!A-Za-z0-9-]*) die "FM_SYNC_REPOSITORY owner is invalid" ;;
  esac
  case "$mode:$conflict" in
    conflict:true)
      title='chore: sync fork with upstream (conflicts require review)'
      conflict_note='Git reported conflicts. The branch carries the upstream tree so GitHub can expose the conflicting paths for human resolution.'
      ;;
    agents-correction:false)
      title='chore: restore upstream AGENTS.md'
      conflict_note='Git produced a one-parent correction commit that restores AGENTS.md from the recorded upstream head.'
      ;;
    merge:false)
      title='chore: sync fork with upstream'
      conflict_note='Git produced a clean two-parent merge commit for review.'
      ;;
    *) die "FM_SYNC_MODE and FM_SYNC_CONFLICT are inconsistent" ;;
  esac

  body_file=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/firstmate-upstream-sync.XXXXXX")
  trap 'rm -f "$body_file"' EXIT HUP INT TERM
  {
    printf '## Upstream sync\n\n'
    printf -- "- Fork base before this refresh: \`%s\`\n" "$base_sha"
    printf -- "- Upstream source: \`%s\`\n" "$upstream_repository"
    printf -- "- Upstream head: \`%s\`\n" "$upstream_sha"
    printf -- '- Status: %s\n\n' "$conflict_note"
    printf 'This automation only opens or refreshes this PR; it never merges or enables auto-merge.\n'
    printf 'The recorded fork-base and upstream-head SHAs are the rollback evidence for this sync.\n'
    printf "Keep upstream \`AGENTS.md\` as the authoritative project baseline when resolving conflicts.\n"
    printf "Do not add fork-private \`data/\`, \`state/\`, \`config/\`, \`projects/\`, or \`.no-mistakes/\` content.\n"
  } > "$body_file"

  pr_number=$(gh api --method GET "repos/$repository/pulls" \
    -f state=open -f base="$base_branch" \
    -f "head=$repository_owner:$sync_branch" \
    --jq '.[0].number // empty')
  if [ -n "$pr_number" ]; then
    gh pr edit "$pr_number" --repo "$repository" --title "$title" --body-file "$body_file"
  else
    pr_url=$(gh pr create --repo "$repository" --base "$base_branch" \
      --head "$sync_branch" --title "$title" --body-file "$body_file")
    printf '%s\n' "$pr_url"
    return 0
  fi
  gh pr view "$pr_number" --repo "$repository" --json url --jq .url
}

case "${1:-}" in
  prepare) prepare ;;
  upsert-pr) upsert_pr ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
