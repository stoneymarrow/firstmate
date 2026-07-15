#!/usr/bin/env bash
# Behavior coverage for the fork-only, review-required upstream sync workflow.
# Uses local bare remotes and a fake gh so it never touches GitHub.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-upstream-sync.sh"
WORKFLOW="$ROOT/.github/workflows/upstream-sync.yml"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-upstream-sync-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM
fm_git_identity

init_seed() {
  dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" checkout -qb main
  printf '# Firstmate test baseline\n' > "$dir/AGENTS.md"
  printf 'common\n' > "$dir/shared.txt"
  git -C "$dir" add AGENTS.md shared.txt
  git -C "$dir" commit -qm 'initial baseline'
}

make_bare_pair() {
  case_dir=$1
  init_seed "$case_dir/seed"
  git clone -q --bare "$case_dir/seed" "$case_dir/origin.git"
  git clone -q --bare "$case_dir/seed" "$case_dir/upstream.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$case_dir/upstream.git" symbolic-ref HEAD refs/heads/main
}

clone_fork_worktree() {
  case_dir=$1
  git clone -q "$case_dir/origin.git" "$case_dir/work"
  git -C "$case_dir/work" remote add upstream "$case_dir/upstream.git"
}

advance_remote() {
  bare=$1
  work=$2
  file=$3
  content=$4
  message=$5
  git clone -q "$bare" "$work"
  mkdir -p "$(dirname "$work/$file")"
  printf '%s\n' "$content" > "$work/$file"
  git -C "$work" add "$file"
  git -C "$work" commit -qm "$message"
  git -C "$work" push -q origin main
}

test_clean_sync_targets_fork_branch_and_is_idempotent() {
  case_dir="$TMP_ROOT/clean"
  mkdir -p "$case_dir"
  make_bare_pair "$case_dir"
  advance_remote "$case_dir/origin.git" "$case_dir/origin-work" \
    AGENTS.md '# Fork-local instructions that must not survive' 'edit fork agents'
  advance_remote "$case_dir/upstream.git" "$case_dir/upstream-work" \
    upstream.txt 'upstream change' 'advance upstream'
  clone_fork_worktree "$case_dir"

  base_before=$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)
  upstream_before=$(git -C "$case_dir/upstream.git" for-each-ref \
    --format='%(refname):%(objectname)' refs/heads)
  first_output="$case_dir/first.output"
  (
    cd "$case_dir/work"
    FM_SYNC_OUTPUT="$first_output" "$SCRIPT" prepare
  )

  sync_ref=$(git -C "$case_dir/origin.git" rev-parse refs/heads/automation/upstream-sync)
  parent_line=$(git -C "$case_dir/origin.git" rev-list --parents -n 1 "$sync_ref")
  parent_count=$(printf '%s\n' "$parent_line" | awk '{print NF}')
  first_parent=$(printf '%s\n' "$parent_line" | awk '{print $2}')
  second_parent=$(printf '%s\n' "$parent_line" | awk '{print $3}')
  [ "$parent_count" -eq 3 ] || fail 'clean sync must be an explicit two-parent merge commit'
  [ "$first_parent" = "$base_before" ] || fail 'clean sync first parent must be the fork base'
  upstream_head=$(git -C "$case_dir/upstream.git" rev-parse refs/heads/main)
  [ "$second_parent" = "$upstream_head" ] || fail 'clean sync second parent must be upstream head'
  sync_agents=$(git -C "$case_dir/origin.git" show "$sync_ref:AGENTS.md")
  upstream_agents=$(git -C "$case_dir/upstream.git" show "$upstream_head:AGENTS.md")
  [ "$sync_agents" = "$upstream_agents" ] || \
    fail 'clean sync must restore upstream AGENTS.md exactly'
  [ "$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)" = "$base_before" ] || \
    fail 'prepare must never push the fork default branch'
  [ "$(git -C "$case_dir/upstream.git" for-each-ref --format='%(refname):%(objectname)' refs/heads)" = "$upstream_before" ] || \
    fail 'prepare must never push or mutate upstream refs'
  [ "$(git -C "$case_dir/work" remote get-url --push upstream)" = DISABLED ] || \
    fail 'prepare must disable the upstream push URL'
  assert_grep 'has_delta=true' "$first_output" 'clean sync must report an upstream delta'
  assert_grep 'conflict=false' "$first_output" 'clean sync must report no conflict'

  second_output="$case_dir/second.output"
  (
    cd "$case_dir/work"
    FM_SYNC_OUTPUT="$second_output" "$SCRIPT" prepare
  )
  second_ref=$(git -C "$case_dir/origin.git" rev-parse refs/heads/automation/upstream-sync)
  [ "$second_ref" = "$sync_ref" ] || fail 'identical rerun must not rewrite the sync branch'
  assert_grep 'branch_updated=false' "$second_output" 'identical rerun must report no branch update'
  pass 'clean sync targets only the fork review branch and is idempotent'
}

test_no_delta_is_a_noop() {
  case_dir="$TMP_ROOT/no-delta"
  mkdir -p "$case_dir"
  make_bare_pair "$case_dir"
  clone_fork_worktree "$case_dir"
  output="$case_dir/output"
  (
    cd "$case_dir/work"
    FM_SYNC_OUTPUT="$output" "$SCRIPT" prepare
  )
  assert_grep 'has_delta=false' "$output" 'equal fork and upstream must report no delta'
  ! git -C "$case_dir/origin.git" show-ref --verify --quiet \
    refs/heads/automation/upstream-sync || fail 'no-delta run must not create a sync branch'
  pass 'no upstream delta is a no-op'
}

test_agents_drift_is_corrected_without_upstream_delta() {
  case_dir="$TMP_ROOT/agents-drift"
  mkdir -p "$case_dir"
  make_bare_pair "$case_dir"
  advance_remote "$case_dir/origin.git" "$case_dir/origin-work" \
    AGENTS.md '# Fork-local instructions that must be corrected' 'drift fork agents'
  clone_fork_worktree "$case_dir"
  output="$case_dir/output"
  (
    cd "$case_dir/work"
    FM_SYNC_OUTPUT="$output" "$SCRIPT" prepare
  )
  sync_ref=$(git -C "$case_dir/origin.git" rev-parse refs/heads/automation/upstream-sync)
  upstream_head=$(git -C "$case_dir/upstream.git" rev-parse refs/heads/main)
  [ "$(git -C "$case_dir/origin.git" show "$sync_ref:AGENTS.md")" = \
      "$(git -C "$case_dir/upstream.git" show "$upstream_head:AGENTS.md")" ] || \
    fail 'AGENTS.md drift must be corrected from upstream'
  assert_grep 'has_delta=true' "$output" 'AGENTS.md drift must create a review delta'
  pass 'upstream AGENTS.md authority is restored without a commit delta'
}

test_private_paths_are_refused_before_early_exit() {
  case_dir="$TMP_ROOT/private-no-delta"
  mkdir -p "$case_dir"
  make_bare_pair "$case_dir"
  advance_remote "$case_dir/origin.git" "$case_dir/origin-work" \
    data/private.txt 'fork-private' 'track fork-private path'
  clone_fork_worktree "$case_dir"
  if (
    cd "$case_dir/work"
    "$SCRIPT" prepare >"$case_dir/stdout" 2>"$case_dir/stderr"
  ); then
    fail 'base-only private paths must fail before the no-delta exit'
  fi
  assert_grep 'refusing tracked fleet-private paths' "$case_dir/stderr" \
    'private-path refusal must explain the failure'
  ! git -C "$case_dir/origin.git" show-ref --verify --quiet \
    refs/heads/automation/upstream-sync || fail 'private paths must not create a sync branch'
  pass 'fork-private paths are refused before no-delta handling'
}

test_conflict_stages_upstream_for_human_review() {
  case_dir="$TMP_ROOT/conflict"
  mkdir -p "$case_dir"
  make_bare_pair "$case_dir"
  advance_remote "$case_dir/origin.git" "$case_dir/origin-work" \
    shared.txt 'fork version' 'diverge fork'
  advance_remote "$case_dir/upstream.git" "$case_dir/upstream-work" \
    shared.txt 'upstream version' 'diverge upstream'
  clone_fork_worktree "$case_dir"
  base_before=$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)
  output="$case_dir/output"
  (
    cd "$case_dir/work"
    FM_SYNC_OUTPUT="$output" "$SCRIPT" prepare
  )
  sync_ref=$(git -C "$case_dir/origin.git" rev-parse refs/heads/automation/upstream-sync)
  [ "$(git -C "$case_dir/origin.git" show "$sync_ref:shared.txt")" = 'upstream version' ] || \
    fail 'conflict branch must carry the upstream tree for PR conflict review'
  [ "$(git -C "$case_dir/origin.git" rev-parse refs/heads/main)" = "$base_before" ] || \
    fail 'conflict handling must leave fork main untouched'
  assert_grep 'conflict=true' "$output" 'conflict run must require human review'
  assert_grep 'Upstream-Sync-Managed: true' \
    <(git -C "$case_dir/origin.git" show -s --format=%B "$sync_ref") \
    'conflict marker must identify the automation-owned branch'
  pass 'conflicts become a reviewable fork PR branch without touching main'
}

test_existing_pr_is_refreshed_without_duplicate_or_merge() {
  case_dir="$TMP_ROOT/pr"
  fakebin=$(fm_fakebin "$case_dir")
  log="$case_dir/gh.log"
  body="$case_dir/body.md"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  'pr list')
    case "$*" in
      *'headRepositoryOwner.login == "stoneymarrow"'*) printf '42\n' ;;
      *) printf 'missing repository-owner filter\n' >&2; exit 97 ;;
    esac
    ;;
  'pr edit')
    while [ "$#" -gt 0 ]; do
      if [ "$1" = '--body-file' ]; then
        shift
        cp "$1" "$GH_BODY"
        break
      fi
      shift
    done
    ;;
  'pr view') printf 'https://github.test/fork/firstmate/pull/42\n' ;;
  'pr create') printf 'duplicate PR attempted\n' >&2; exit 99 ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 98 ;;
esac
SH
  chmod +x "$fakebin/gh"
  GH_LOG="$log" GH_BODY="$body" PATH="$fakebin:$PATH" \
    FM_SYNC_REPOSITORY='stoneymarrow/firstmate' \
    FM_SYNC_BASE_BRANCH=main \
    FM_SYNC_BRANCH=automation/upstream-sync \
    FM_SYNC_BASE_SHA=1111111111111111111111111111111111111111 \
    FM_SYNC_UPSTREAM_SHA=2222222222222222222222222222222222222222 \
    FM_SYNC_UPSTREAM_REPOSITORY='kunchenguid/firstmate' \
    FM_SYNC_CONFLICT=false \
    "$SCRIPT" upsert-pr >/dev/null
  assert_grep 'pr edit 42' "$log" 'existing sync PR must be refreshed'
  assert_grep '--json number,headRepositoryOwner' "$log" \
    'existing PR lookup must request the head repository owner'
  assert_no_grep 'pr create' "$log" 'existing sync PR must not be duplicated'
  assert_grep 'it never merges or enables auto-merge' "$body" \
    'PR body must state the no-auto-merge contract'
  assert_grep "upstream \`AGENTS.md\` as the authoritative project baseline" "$body" \
    'PR body must preserve upstream AGENTS.md authority'
  pass 'existing PR is refreshed and remains review-only'
}

test_external_fork_pr_does_not_collide_with_sync_pr() {
  case_dir="$TMP_ROOT/pr-owner-collision"
  fakebin=$(fm_fakebin "$case_dir")
  log="$case_dir/gh.log"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  'pr list')
    case "$*" in
      *'headRepositoryOwner.login == "stoneymarrow"'*) : ;;
      *) printf 'missing repository-owner filter\n' >&2; exit 97 ;;
    esac
    ;;
  'pr create') printf 'https://github.test/stoneymarrow/firstmate/pull/43\n' ;;
  'pr edit') printf 'external fork PR was edited\n' >&2; exit 99 ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 98 ;;
esac
SH
  chmod +x "$fakebin/gh"
  GH_LOG="$log" PATH="$fakebin:$PATH" \
    FM_SYNC_REPOSITORY='stoneymarrow/firstmate' \
    FM_SYNC_BASE_BRANCH=main \
    FM_SYNC_BRANCH=automation/upstream-sync \
    FM_SYNC_BASE_SHA=1111111111111111111111111111111111111111 \
    FM_SYNC_UPSTREAM_SHA=2222222222222222222222222222222222222222 \
    FM_SYNC_UPSTREAM_REPOSITORY='kunchenguid/firstmate' \
    FM_SYNC_CONFLICT=false \
    "$SCRIPT" upsert-pr >/dev/null
  assert_grep 'pr create' "$log" 'external fork collision must create the fork-local PR'
  assert_no_grep 'pr edit' "$log" 'external fork collision must not edit another PR'
  pass 'same-branch external fork PRs cannot collide with the sync PR'
}

test_workflow_contract_is_static_and_fork_only() {
  assert_grep 'schedule:' "$WORKFLOW" 'workflow must run daily'
  assert_grep 'github.event.repository.fork == true' "$WORKFLOW" \
    'workflow must be inert in the upstream repository'
  assert_grep "GITHUB_REPOSITORY\" = 'stoneymarrow/firstmate'" "$WORKFLOW" \
    'workflow must pin the only writable repository'
  assert_grep "upstream_repository\" = 'kunchenguid/firstmate'" "$WORKFLOW" \
    'workflow must pin the fetch-only upstream repository'
  assert_grep 'FM_SYNC_BRANCH: automation/upstream-sync' "$WORKFLOW" \
    'workflow must target the dedicated review branch'
  assert_grep 'git remote set-url --push upstream DISABLED' "$WORKFLOW" \
    'workflow must configure upstream as fetch-only'
  assert_grep "git push \"\$origin_remote\"" "$SCRIPT" \
    'implementation must push only through the fork remote variable'
  assert_no_grep "git push \"\$upstream_remote\"" "$SCRIPT" \
    'implementation must contain no upstream push path'
  assert_no_grep 'gh pr merge' "$SCRIPT" 'implementation must never merge a PR'
  assert_no_grep 'gh pr merge' "$WORKFLOW" 'workflow must never merge a PR'
  pass 'workflow is daily, fork-only, branch-targeted, and never auto-merges'
}

test_clean_sync_targets_fork_branch_and_is_idempotent
test_no_delta_is_a_noop
test_agents_drift_is_corrected_without_upstream_delta
test_private_paths_are_refused_before_early_exit
test_conflict_stages_upstream_for_human_review
test_existing_pr_is_refreshed_without_duplicate_or_merge
test_external_fork_pr_does_not_collide_with_sync_pr
test_workflow_contract_is_static_and_fork_only
