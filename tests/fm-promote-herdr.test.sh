#!/usr/bin/env bash
# Focused scout-to-ship promotion coverage for the Herdr adapter.
# The stateful fake models only Herdr and never touches a live Herdr session.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-promote-herdr.XXXXXX")
LOCK_PATHS=
trap 'for lock in $LOCK_PATHS; do rm -rf "$lock"; done; rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() {
  case "$1" in *"$2"*) : ;; *) fail "$3" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "$3" ;; *) : ;; esac
}

make_stateful_herdr() {  # <case-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/herdr"
  cat > "$dir/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s' "${1:-}" >> "$FM_HERDR_LOG"
for arg in "${@:2}"; do printf '\037%s' "$arg" >> "$FM_HERDR_LOG"; done
printf '\n' >> "$FM_HERDR_LOG"
state=$FM_HERDR_STATE
object=${1:-}; action=${2:-}

case "$object:$action" in
  session:list)
    jq -cn --arg socket "$state/fmtest.sock" \
      '{sessions:[{name:"fmtest",running:true,socket_path:$socket}]}'
    ;;
  workspace:list)
    jq -Rn '[inputs | split("\t") | {workspace_id:.[0],label:.[1]}]' < "$state/workspaces.tsv" \
      | jq '{result:{workspaces:.}}'
    ;;
  tab:list)
    workspace=
    [ "${3:-}" != --workspace ] || workspace=${4:-}
    if [ -n "$workspace" ]; then
      jq -Rn --arg workspace "$workspace" '
        [inputs | split("\t")
          | select(.[1] == $workspace)
          | {tab_id:.[0],workspace_id:.[1],label:.[2]}]
      ' < "$state/tabs.tsv" | jq '{result:{tabs:.}}'
    else
      jq -Rn '[inputs | split("\t") | {tab_id:.[0],workspace_id:.[1],label:.[2]}]' \
        < "$state/tabs.tsv" | jq '{result:{tabs:.}}'
    fi
    ;;
  pane:list)
    workspace=
    [ "${3:-}" != --workspace ] || workspace=${4:-}
    jq -Rn --arg workspace "$workspace" '
      [inputs | split("\t")
        | select($workspace == "" or .[1] == $workspace)
        | {pane_id:.[0],workspace_id:.[1],tab_id:.[2],label:.[3]}]
    ' < "$state/panes.tsv" | jq '{result:{panes:.}}'
    ;;
  pane:get)
    pane=${3:-}
    row=$(awk -F '\t' -v pane="$pane" '$1 == pane { print; found += 1 } END { if (found != 1) exit 1 }' \
      "$state/panes.tsv") || { jq -cn '{error:{code:"pane_not_found"}}'; exit 1; }
    IFS=$'\t' read -r pane_id workspace tab label cwd <<EOF
$row
EOF
    jq -cn --arg pane "$pane_id" --arg workspace "$workspace" --arg tab "$tab" \
      --arg label "$label" --arg cwd "$cwd" \
      '{result:{pane:{pane_id:$pane,workspace_id:$workspace,tab_id:$tab,label:$label,cwd:$cwd}}}'
    ;;
  tab:rename)
    tab=${3:-}; label=${4:-}
    if [ -e "$state/fail-tab-once" ]; then rm -f "$state/fail-tab-once"; exit 1; fi
    tmp=$(mktemp "$state/tabs.XXXXXX")
    found=0
    while IFS=$'\t' read -r current workspace old_label; do
      if [ "$current" = "$tab" ]; then old_label=$label; found=$((found + 1)); fi
      printf '%s\t%s\t%s\n' "$current" "$workspace" "$old_label" >> "$tmp"
    done < "$state/tabs.tsv"
    [ "$found" -eq 1 ] || { rm -f "$tmp"; exit 1; }
    mv "$tmp" "$state/tabs.tsv"
    workspace=$(awk -F '\t' -v tab="$tab" '$1 == tab { print $2 }' "$state/tabs.tsv")
    jq -cn --arg tab "$tab" --arg workspace "$workspace" --arg label "$label" \
      '{result:{tab:{tab_id:$tab,workspace_id:$workspace,label:$label}}}'
    ;;
  pane:rename)
    pane=${3:-}; label=${4:-}
    if [ -e "$state/fail-pane-once" ]; then rm -f "$state/fail-pane-once"; exit 1; fi
    tmp=$(mktemp "$state/panes.XXXXXX")
    found=0; workspace=; tab=
    while IFS=$'\t' read -r current current_workspace current_tab old_label cwd; do
      if [ "$current" = "$pane" ]; then
        old_label=$label; workspace=$current_workspace; tab=$current_tab; found=$((found + 1))
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$current" "$current_workspace" "$current_tab" "$old_label" "$cwd" >> "$tmp"
    done < "$state/panes.tsv"
    [ "$found" -eq 1 ] || { rm -f "$tmp"; exit 1; }
    mv "$tmp" "$state/panes.tsv"
    jq -cn --arg pane "$pane" --arg workspace "$workspace" --arg tab "$tab" --arg label "$label" \
      '{result:{pane:{pane_id:$pane,workspace_id:$workspace,tab_id:$tab,label:$label}}}'
    ;;
  *)
    printf 'unexpected fake Herdr call: %s %s\n' "$object" "$action" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$dir/bin/herdr"
  printf '%s' "$dir/bin"
}

write_meta() {  # <home> <id> <kind> <workspace> <tab> <pane> <workspace-label> <task-label>
  local home=$1 id=$2 kind=$3 workspace=$4 tab=$5 pane=$6 workspace_label=$7 task_label=$8
  printf '%s\n' \
    "window=fmtest:$pane" \
    "worktree=$home/worktree" \
    'project=/srv/payments' \
    'harness=pi' \
    "kind=$kind" \
    'mode=local-only' \
    'yolo=off' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    "herdr_workspace_id=$workspace" \
    "herdr_tab_id=$tab" \
    "herdr_pane_id=$pane" \
    "display_label=$task_label" \
    "herdr_workspace_label=$workspace_label" \
    "herdr_tab_label=$task_label" \
    "herdr_pane_label=$task_label" > "$home/state/$id.meta"
}

setup_flat() {  # <case-name> [task-label]
  local name=$1 task_label=${2:-'invoice-check · scout'} dir home fake
  dir="$TMP_ROOT/$name"; home="$dir/home"
  mkdir -p "$home/state" "$home/worktree" "$dir/herdr"
  : > "$dir/herdr/fmtest.sock"
  printf 'w1\tpayments · primary\n' > "$dir/herdr/workspaces.tsv"
  printf 'w1:t1\tw1\t%s\n' "$task_label" > "$dir/herdr/tabs.tsv"
  printf 'w1:p1\tw1\tw1:t1\t%s\t/srv/payments\n' "$task_label" > "$dir/herdr/panes.tsv"
  : > "$dir/herdr.log"
  fake=$(make_stateful_herdr "$dir")
  write_meta "$home" invoice-check scout w1 w1:t1 w1:p1 'payments · primary' "$task_label"
  printf '%s\t%s\t%s' "$dir" "$home" "$fake"
}

setup_projected() {  # <case-name> <task-label>
  local name=$1 task_label=$2 dir home fake token child
  token=AbCdEfGhIjKlMnOpQrStUv
  child="└ invoice-check · p:$token"
  dir="$TMP_ROOT/$name"; home="$dir/home"
  mkdir -p "$home/state" "$home/worktree" "$dir/herdr"
  : > "$dir/herdr/fmtest.sock"
  printf 'w1\tpayments · primary\nw2\t%s\n' "$child" > "$dir/herdr/workspaces.tsv"
  printf 'w2:t2\tw2\t%s\n' "$task_label" > "$dir/herdr/tabs.tsv"
  printf 'w2:p2\tw2\tw2:t2\t%s\t/srv/payments\n' "$task_label" > "$dir/herdr/panes.tsv"
  : > "$dir/herdr.log"
  fake=$(make_stateful_herdr "$dir")
  write_meta "$home" invoice-check scout w2 w2:t2 w2:p2 "$child" "$task_label"
  printf '%s\t%s\t%s' "$dir" "$home" "$fake"
}

write_v3_journal() {  # <home> <kind> <label> [journal-home] [session] [pane]
  local home=$1 kind=$2 label=$3 journal_home=${4:-} session=${5:-fmtest} pane=${6:-w2:p2}
  local token child
  [ -n "$journal_home" ] || journal_home=$(cd "$home" && pwd -P)
  token=AbCdEfGhIjKlMnOpQrStUv
  child="└ invoice-check · p:$token"
  printf '%s\n' \
    'version=3' \
    'task_id=invoice-check' \
    "projection_id=$token" \
    "task_kind=$kind" \
    "home=$journal_home" \
    "session=$session" \
    'workspace_id=w2' \
    'tab_id=w2:t2' \
    "pane_id=$pane" \
    'parent_workspace_id=w1' \
    'parent_label=payments · primary' \
    "workspace_label=$child" \
    "task_label=$label" > "$home/state/invoice-check.herdr-presentation"
}

write_v2_journal() {  # <home>
  local home=$1 canonical_home token child
  canonical_home=$(cd "$home" && pwd -P)
  token=AbCdEfGhIjKlMnOpQrStUv
  child="└ invoice-check · p:$token"
  printf '%s\n' \
    'version=2' \
    'task_id=invoice-check' \
    "projection_id=$token" \
    "home=$canonical_home" \
    'session=fmtest' \
    'workspace_id=w2' \
    'tab_id=w2:t2' \
    'pane_id=w2:p2' \
    'parent_workspace_id=w1' \
    'parent_label=payments · primary' \
    "workspace_label=$child" \
    'task_label=fm-invoice-check' > "$home/state/invoice-check.herdr-presentation"
}

run_promote() {  # <dir> <home> <fake-bin>
  local dir=$1 home=$2 fake=$3
  PATH="$fake:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_HERDR_STATE="$dir/herdr" FM_HERDR_LOG="$dir/herdr.log" \
    "$ROOT/bin/fm-promote.sh" invoice-check
}

write_role_intent() {  # <home> <workspace> <tab> <pane> <old-label>
  local home=$1 workspace=$2 tab=$3 pane=$4 old_label=$5 canonical_home intent
  canonical_home=$(cd "$home" && pwd -P)
  intent="$home/state/invoice-check.herdr-role-transition"
  printf '%s\n' \
    'version=1' \
    'task_id=invoice-check' \
    "home=$canonical_home" \
    'session=fmtest' \
    "workspace_id=$workspace" \
    "tab_id=$tab" \
    "pane_id=$pane" \
    "old_label=$old_label" \
    'target_label=invoice-check · worker' \
    'from_kind=scout' \
    'to_kind=ship' > "$intent"
  chmod 0600 "$intent"
}

assert_promoted_exact() {  # <dir> <home> <workspace> <tab> <pane>
  local dir=$1 home=$2 workspace=$3 tab=$4 pane=$5 calls
  [ "$(grep '^kind=' "$home/state/invoice-check.meta")" = kind=ship ] || fail "metadata kind did not become ship"
  [ "$(grep '^display_label=' "$home/state/invoice-check.meta")" = 'display_label=invoice-check · worker' ] \
    || fail "metadata display label did not become worker"
  [ "$(grep '^herdr_workspace_id=' "$home/state/invoice-check.meta")" = "herdr_workspace_id=$workspace" ] \
    || fail "workspace id changed"
  [ "$(grep '^herdr_tab_id=' "$home/state/invoice-check.meta")" = "herdr_tab_id=$tab" ] || fail "tab id changed"
  [ "$(grep '^herdr_pane_id=' "$home/state/invoice-check.meta")" = "herdr_pane_id=$pane" ] || fail "pane id changed"
  [ "$(awk -F '\t' -v tab="$tab" '$1 == tab { print $3 }' "$dir/herdr/tabs.tsv")" = 'invoice-check · worker' ] \
    || fail "live tab label did not become worker"
  [ "$(awk -F '\t' -v pane="$pane" '$1 == pane { print $4 }' "$dir/herdr/panes.tsv")" = 'invoice-check · worker' ] \
    || fail "live pane label did not become worker"
  [ ! -e "$home/state/invoice-check.herdr-role-transition" ] || fail "converged transition intent remained"
  calls=$(<"$dir/herdr.log")
  assert_not_contains "$calls" $'workspace\037rename' "promotion renamed a workspace"
  assert_not_contains "$calls" $'workspace\037close' "promotion closed a workspace"
}

test_flat_success_and_unchanged_ids() {
  local dir home fake out
  IFS=$'\t' read -r dir home fake <<EOF
$(setup_flat flat-success)
EOF
  out=$(run_promote "$dir" "$home" "$fake" 2>&1) || fail "flat promotion failed: $out"
  assert_contains "$out" 'promoted invoice-check to ship' "flat promotion did not report success"
  assert_promoted_exact "$dir" "$home" w1 w1:t1 w1:p1
  pass "Herdr promotion: flat scout becomes worker without changing exact IDs"
}

test_v3_projected_success() {
  local dir home fake out journal
  IFS=$'\t' read -r dir home fake <<EOF
$(setup_projected projected-v3 'invoice-check · scout')
EOF
  write_v3_journal "$home" scout 'invoice-check · scout'
  out=$(run_promote "$dir" "$home" "$fake" 2>&1) || fail "v3 projected promotion failed: $out"
  assert_promoted_exact "$dir" "$home" w2 w2:t2 w2:p2
  journal="$home/state/invoice-check.herdr-presentation"
  [ "$(grep '^version=' "$journal")" = version=3 ] || fail "v3 journal version changed"
  [ "$(grep '^task_kind=' "$journal")" = task_kind=ship ] || fail "v3 journal kind did not become ship"
  [ "$(grep '^task_label=' "$journal")" = 'task_label=invoice-check · worker' ] \
    || fail "v3 journal label did not become worker"
  pass "Herdr promotion: exact projected v3 binding advances to ship/worker"
}

test_v2_migrates_to_v3() {
  local dir home fake out journal
  IFS=$'\t' read -r dir home fake <<EOF
$(setup_projected projected-v2 fm-invoice-check)
EOF
  write_v2_journal "$home"
  out=$(run_promote "$dir" "$home" "$fake" 2>&1) || fail "v2 projected promotion failed: $out"
  assert_promoted_exact "$dir" "$home" w2 w2:t2 w2:p2
  journal="$home/state/invoice-check.herdr-presentation"
  [ "$(grep '^version=' "$journal")" = version=3 ] || fail "v2 journal did not migrate to v3"
  [ "$(grep '^task_kind=' "$journal")" = task_kind=ship ] || fail "migrated journal kind mismatch"
  [ "$(grep '^task_label=' "$journal")" = 'task_label=invoice-check · worker' ] \
    || fail "migrated journal label mismatch"
  pass "Herdr promotion: legacy v2 binding migrates atomically to v3 ship/worker"
}

test_v1_is_byte_identical() {
  local dir home fake out journal before after token
  IFS=$'\t' read -r dir home fake <<EOF
$(setup_projected projected-v1 'invoice-check · scout')
EOF
  token=AbCdEfGhIjKlMnOpQrStUv
  journal="$home/state/invoice-check.herdr-presentation"
  printf '%s\n' 'version=1' 'task_id=invoice-check' "projection_id=$token" > "$journal"
  before=$(shasum -a 256 "$journal")
  out=$(run_promote "$dir" "$home" "$fake" 2>&1) || fail "v1 projected promotion failed: $out"
  after=$(shasum -a 256 "$journal")
  [ "$before" = "$after" ] || fail "v1 journal changed during promotion"
  assert_promoted_exact "$dir" "$home" w2 w2:t2 w2:p2
  pass "Herdr promotion: token-verified v1 journal remains byte-identical"
}

test_target_collision_refuses_before_intent() {
  local mode dir home fake out status calls
  for mode in tab pane; do
    IFS=$'\t' read -r dir home fake <<EOF
$(setup_flat "target-collision-$mode")
EOF
    printf 'w9\tother · primary\n' >> "$dir/herdr/workspaces.tsv"
    if [ "$mode" = tab ]; then
      printf 'w9:t9\tw9\tinvoice-check · worker\n' >> "$dir/herdr/tabs.tsv"
      printf 'w9:p9\tw9\tw9:t9\tother · worker\t/srv/other\n' >> "$dir/herdr/panes.tsv"
    else
      printf 'w9:t9\tw9\tother · worker\n' >> "$dir/herdr/tabs.tsv"
      printf 'w9:p9\tw9\tw9:t9\tinvoice-check · worker\t/srv/other\n' >> "$dir/herdr/panes.tsv"
    fi
    out=$(run_promote "$dir" "$home" "$fake" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "competing $mode target label was accepted"
    [ ! -e "$home/state/invoice-check.herdr-role-transition" ] || fail "$mode collision created an intent"
    calls=$(<"$dir/herdr.log")
    assert_not_contains "$calls" $'tab\037rename' "$mode collision renamed a tab"
    assert_not_contains "$calls" $'pane\037rename' "$mode collision renamed a pane"
  done
  pass "Herdr promotion: competing tab or pane worker label refuses before mutation"
}

test_partial_failure_retains_intent_and_retry_converges() {
  local dir home fake out status intent
  IFS=$'\t' read -r dir home fake <<EOF
$(setup_flat partial-retry)
EOF
  : > "$dir/herdr/fail-pane-once"
  out=$(run_promote "$dir" "$home" "$fake" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "partial pane failure reported success"
  intent="$home/state/invoice-check.herdr-role-transition"
  [ -f "$intent" ] && [ ! -L "$intent" ] || fail "partial failure did not retain a regular intent"
  [ "$(grep '^kind=' "$home/state/invoice-check.meta")" = kind=scout ] || fail "partial failure published ship metadata"
  [ "$(awk -F '\t' '$1 == "w1:t1" { print $3 }' "$dir/herdr/tabs.tsv")" = 'invoice-check · worker' ] \
    || fail "partial fixture did not retain the successful tab rename"
  [ "$(awk -F '\t' '$1 == "w1:p1" { print $4 }' "$dir/herdr/panes.tsv")" = 'invoice-check · scout' ] \
    || fail "partial fixture unexpectedly renamed the pane"
  out=$(run_promote "$dir" "$home" "$fake" 2>&1) || fail "retry did not converge: $out"
  assert_promoted_exact "$dir" "$home" w1 w1:t1 w1:p1
  pass "Herdr promotion: partial tab/pane failure retains intent and retry converges forward"
}

test_ship_resume_requires_same_validated_intent() {
  local dir home fake out status calls
  IFS=$'\t' read -r dir home fake <<EOF
$(setup_flat ship-resume 'invoice-check · worker')
EOF
  perl -pi -e 's/^kind=scout$/kind=ship/' "$home/state/invoice-check.meta"
  perl -pi -e 's/ · scout$/ · worker/' "$home/state/invoice-check.meta"
  out=$(run_promote "$dir" "$home" "$fake" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "kind=ship without an intent was accepted"
  write_role_intent "$home" w1 w1:t1 w1:p1 'invoice-check · scout'
  out=$(run_promote "$dir" "$home" "$fake" 2>&1) || fail "kind=ship intent resume failed: $out"
  assert_promoted_exact "$dir" "$home" w1 w1:t1 w1:p1
  calls=$(<"$dir/herdr.log")
  assert_not_contains "$calls" $'tab\037rename' "already-target ship resume renamed its tab"
  assert_not_contains "$calls" $'pane\037rename' "already-target ship resume renamed its pane"
  pass "Herdr promotion: kind=ship resumes only the same validated intent"
}

test_malformed_metadata_refuses_without_mutation() {
  local dir home fake out status calls
  IFS=$'\t' read -r dir home fake <<EOF
$(setup_flat malformed-meta)
EOF
  printf 'herdr_session=fmtest\n' >> "$home/state/invoice-check.meta"
  out=$(run_promote "$dir" "$home" "$fake" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "duplicate Herdr session metadata was accepted"
  calls=$(<"$dir/herdr.log")
  assert_not_contains "$calls" $'tab\037rename' "malformed metadata renamed a tab"
  assert_not_contains "$calls" $'pane\037rename' "malformed metadata renamed a pane"
  [ ! -e "$home/state/invoice-check.herdr-role-transition" ] || fail "malformed metadata created an intent"
  pass "Herdr promotion: malformed exact metadata refuses before mutation"
}

test_journal_refusals_before_mutation() {
  local mode dir home fake out status calls other journal target canonical_home
  for mode in malformed symlink cross-home wrong-session endpoint-mismatch; do
    IFS=$'\t' read -r dir home fake <<EOF
$(setup_projected "journal-$mode" 'invoice-check · scout')
EOF
    journal="$home/state/invoice-check.herdr-presentation"
    case "$mode" in
      malformed) printf 'version=3\ntask_id=invoice-check\n' > "$journal" ;;
      symlink)
        target="$dir/foreign-journal"
        write_v3_journal "$home" scout 'invoice-check · scout'
        mv "$journal" "$target"
        ln -s "$target" "$journal"
        ;;
      cross-home)
        other="$dir/other-home"; mkdir -p "$other"
        write_v3_journal "$home" scout 'invoice-check · scout' "$other"
        ;;
      wrong-session)
        canonical_home=$(cd "$home" && pwd -P)
        write_v3_journal "$home" scout 'invoice-check · scout' "$canonical_home" other-session
        ;;
      endpoint-mismatch)
        canonical_home=$(cd "$home" && pwd -P)
        write_v3_journal "$home" scout 'invoice-check · scout' "$canonical_home" fmtest other:pane
        ;;
    esac
    out=$(run_promote "$dir" "$home" "$fake" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$mode presentation journal was accepted"
    calls=$(<"$dir/herdr.log")
    assert_not_contains "$calls" $'tab\037rename' "$mode journal renamed a tab"
    assert_not_contains "$calls" $'pane\037rename' "$mode journal renamed a pane"
    [ ! -e "$home/state/invoice-check.herdr-role-transition" ] || fail "$mode journal created an intent"
  done
  pass "Herdr promotion: malformed, symlinked, cross-home, wrong-session, and endpoint-mismatched journals refuse"
}

test_task_and_session_lock_contention() {
  local mode dir home fake out status lock calls
  for mode in task session; do
    IFS=$'\t' read -r dir home fake <<EOF
$(setup_flat "lock-$mode")
EOF
    if [ "$mode" = task ]; then
      lock="$home/state/.spawn-invoice-check.lock"
    else
      lock=$(PATH="$fake:$PATH" FM_HOME="$home" FM_HERDR_STATE="$dir/herdr" \
        FM_HERDR_LOG="$dir/herdr.log" bash -c '
          . "$0/bin/backends/herdr.sh"
          fm_backend_herdr_presentation_session_lock_path fmtest
        ' "$ROOT") || fail "could not derive test session lock"
    fi
    mkdir "$lock" || fail "could not create $mode contention lock"
    printf '%s\n' "$$" > "$lock/pid"
    LOCK_PATHS="$LOCK_PATHS $lock"
    out=$(run_promote "$dir" "$home" "$fake" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$mode lock contention was ignored"
    rm -rf "$lock"
    calls=$(<"$dir/herdr.log")
    assert_not_contains "$calls" $'tab\037rename' "$mode lock contention renamed a tab"
    assert_not_contains "$calls" $'pane\037rename' "$mode lock contention renamed a pane"
    [ ! -e "$home/state/invoice-check.herdr-role-transition" ] || fail "$mode lock contention created an intent"
  done
  pass "Herdr promotion: task lock then exact named-session lock both refuse contention"
}

test_teardown_refuses_unresolved_intent() {
  local dir home fake out status non_herdr order meta intent cleanup_log
  IFS=$'\t' read -r dir home fake <<EOF
$(setup_flat teardown-intent)
EOF
  perl -pi -e 's/^kind=scout$/kind=ship/' "$home/state/invoice-check.meta"
  printf 'unresolved\n' > "$home/state/invoice-check.herdr-role-transition"
  out=$(PATH="$fake:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_HERDR_STATE="$dir/herdr" FM_HERDR_LOG="$dir/herdr.log" \
    "$ROOT/bin/fm-teardown.sh" invoice-check --force 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "teardown accepted an unresolved role-transition intent"
  assert_contains "$out" 'unresolved Herdr role transition' "teardown refusal did not explain the role transition"
  [ -f "$home/state/invoice-check.meta" ] || fail "teardown removed metadata despite unresolved intent"

  for order in herdr-first herdr-last; do
    IFS=$'\t' read -r dir home fake <<EOF
$(setup_flat "teardown-duplicate-$order")
EOF
    meta="$home/state/invoice-check.meta"
    intent="$home/state/invoice-check.herdr-role-transition"
    perl -pi -e 's/^kind=scout$/kind=ship/' "$meta"
    if [ "$order" = herdr-first ]; then
      printf 'backend=fixture\n' >> "$meta"
    else
      perl -pi -e 's/^backend=herdr$/backend=fixture\nbackend=herdr/' "$meta"
    fi
    printf 'unresolved\n' > "$intent"
    cp "$meta" "$dir/meta.before"
    cp "$intent" "$dir/intent.before"
    cleanup_log="$dir/cleanup.log"
    : > "$cleanup_log"
    cat > "$fake/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse cleanup\n' >> "${FM_CLEANUP_LOG:?}"
exit 0
SH
    chmod +x "$fake/treehouse"
    out=$(PATH="$fake:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_HERDR_STATE="$dir/herdr" FM_HERDR_LOG="$dir/herdr.log" \
      FM_CLEANUP_LOG="$cleanup_log" "$ROOT/bin/fm-teardown.sh" invoice-check --force 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$order duplicate backend fields bypassed Herdr transition refusal"
    cmp -s "$dir/meta.before" "$meta" || fail "$order refusal changed or removed metadata"
    cmp -s "$dir/intent.before" "$intent" || fail "$order refusal changed or removed transition intent"
    [ -d "$home/worktree" ] || fail "$order refusal removed the worktree"
    [ ! -s "$dir/herdr.log" ] || fail "$order refusal called endpoint cleanup"
    [ ! -s "$cleanup_log" ] || fail "$order refusal called worktree cleanup"
  done

  non_herdr="$TMP_ROOT/teardown-non-herdr"; mkdir -p "$non_herdr/state" "$non_herdr/data" "$non_herdr/config"
  printf '%s\n' 'window=fixture-target' 'worktree=/missing/worktree' 'project=/missing/project' \
    'kind=ship' 'backend=fixture' > "$non_herdr/state/plain.meta"
  printf 'unresolved\n' > "$non_herdr/state/plain.herdr-role-transition"
  out=$(FM_HOME="$non_herdr" FM_STATE_OVERRIDE="$non_herdr/state" \
    FM_DATA_OVERRIDE="$non_herdr/data" FM_CONFIG_OVERRIDE="$non_herdr/config" \
    "$ROOT/bin/fm-teardown.sh" plain --force 2>&1)
  status=$?
  assert_not_contains "$out" 'unresolved Herdr role transition' \
    "synthetic non-Herdr metadata was blocked by a Herdr transition sentinel"
  pass "Herdr teardown: transition refusal applies only to validated Herdr metadata"
}

test_non_herdr_compatibility() {
  local home out expected before status
  home="$TMP_ROOT/non-herdr/home"; mkdir -p "$home/state"
  printf '%s\n' 'window=fm-test' 'worktree=/tmp/fm-test' 'project=/tmp/project' \
    'kind=scout' 'custom=preserved' > "$home/state/plain.meta"
  mkdir "$home/state/.spawn-plain.lock"
  printf '%s\n' "$$" > "$home/state/.spawn-plain.lock/pid"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" plain 2>&1) \
    || fail "non-Herdr promotion failed while its Herdr-only lock name was busy: $out"
  expected=$(printf '%s\n' 'window=fm-test' 'worktree=/tmp/fm-test' 'project=/tmp/project' \
    'custom=preserved' 'kind=ship')
  [ "$(cat "$home/state/plain.meta")" = "$expected" ] \
    || fail "non-Herdr metadata bytes differ from the legacy kind-only block"
  [ -d "$home/state/.spawn-plain.lock" ] || fail "generic promotion touched an unrelated busy lock"

  printf '%s\n' 'window=fm-test' 'worktree=/tmp/fm-test' 'project=/tmp/project' \
    'kind=scout' 'backend=herdr' 'backend=fixture' > "$home/state/malformed.meta"
  before=$(cat "$home/state/malformed.meta")
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" malformed 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "competing backend fields fell through to generic promotion"
  [ "$(cat "$home/state/malformed.meta")" = "$before" ] || fail "malformed Herdr claim changed metadata"
  rm -rf "$home/state/.spawn-plain.lock"
  pass "Promotion compatibility: generic bytes stay legacy while malformed Herdr claims refuse"
}

test_flat_success_and_unchanged_ids
test_v3_projected_success
test_v2_migrates_to_v3
test_v1_is_byte_identical
test_target_collision_refuses_before_intent
test_partial_failure_retains_intent_and_retry_converges
test_ship_resume_requires_same_validated_intent
test_malformed_metadata_refuses_without_mutation
test_journal_refusals_before_mutation
test_task_and_session_lock_contention
test_teardown_refuses_unresolved_intent
test_non_herdr_compatibility
