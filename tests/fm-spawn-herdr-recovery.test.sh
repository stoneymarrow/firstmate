#!/usr/bin/env bash
# Focused fake-Herdr coverage for spawn recovery evidence separation.
# No live Herdr command or non-Herdr runtime implementation is read.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-herdr-recovery.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3" ;; *) : ;; esac; }

make_fake_herdr() {  # <fixture-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/responses"
  cat > "$dir/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s' "${1:-}" >> "$FM_HERDR_LOG"
shift || true
for arg in "$@"; do printf '\037%s' "$arg" >> "$FM_HERDR_LOG"; done
printf '\n' >> "$FM_HERDR_LOG"
count_file="$FM_HERDR_RESPONSES/.count"
count=0
[ ! -f "$count_file" ] || IFS= read -r count < "$count_file"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
status=0
[ ! -f "$FM_HERDR_RESPONSES/$count.exit" ] || IFS= read -r status < "$FM_HERDR_RESPONSES/$count.exit"
[ ! -f "$FM_HERDR_RESPONSES/$count.out" ] || cat "$FM_HERDR_RESPONSES/$count.out"
exit "$status"
SH
  chmod +x "$dir/bin/herdr"
  printf '%s' "$dir/bin"
}

response() { printf '%s\n' "$3" > "$1/responses/$2.out"; }
run_adapter() {  # <home> <fake-bin> <log> <command> [args...]
  local home=$1 fake=$2 log=$3 command=$4
  shift 4
  PATH="$fake:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" \
    FM_HERDR_RESPONSES="${fake%/bin}/responses" \
    bash -c '. "$0/bin/backends/herdr.sh"; "$1" "${@:2}"' "$ROOT" "$command" "$@"
}
write_task_meta() {  # <path> <project> <workspace> <tab> <pane> <workspace-label>
  printf '%s\n' \
    'backend=herdr' 'kind=ship' "project=$2" 'herdr_session=fmtest' \
    "herdr_workspace_id=$3" "herdr_tab_id=$4" "herdr_pane_id=$5" \
    'display_label=invoice-check · worker' "herdr_workspace_label=$6" \
    'herdr_tab_label=invoice-check · worker' 'herdr_pane_label=invoice-check · worker' > "$1"
}

# A v1 journal has no parent id. Its projected task record is excluded from
# normal project discovery, so the child can neither be adopted nor mutated.
# An unowned same-label flat parent still refuses.
test_v1_flat_fallback_excludes_projected_child() {
  local dir home meta log fake out status calls token child
  token=AbCdEfGhIjKlMnOpQrStUv
  child="└ invoice-check · p:$token"

  dir="$TMP_ROOT/v1-create"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"
  write_task_meta "$meta" /srv/payments child child:t1 child:p1 "$child"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 "{\"result\":{\"workspaces\":[{\"workspace_id\":\"child\",\"label\":\"$child\"}]}}"
  response "$dir" 2 '{"result":{"workspace":{"workspace_id":"parent","label":"payments · project"},"tab":{"tab_id":"parent:t1"},"root_pane":{"pane_id":"parent:p1"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
    fmtest /srv/payments '' "$meta") || fail "v1 fallback could not create a lawful flat parent: $out"
  [ "$out" = parent ] || fail "v1 fallback returned '$out'"
  calls=$(cat "$log")
  assert_not_contains "$calls" $'rename\037child' "v1 fallback renamed its projected child"
  assert_not_contains "$calls" $'close\037child' "v1 fallback closed its projected child"

  dir="$TMP_ROOT/v1-unowned-parent"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"
  write_task_meta "$meta" /srv/payments child child:t1 child:p1 "$child"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 "{\"result\":{\"workspaces\":[{\"workspace_id\":\"child\",\"label\":\"$child\"},{\"workspace_id\":\"foreign\",\"label\":\"payments · project\"}]}}"
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
    fmtest /srv/payments '' "$meta" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "v1 fallback adopted an unowned same-label parent"
  calls=$(cat "$log")
  assert_not_contains "$calls" $'workspace\037create' "v1 unowned-parent refusal created a workspace"
  assert_not_contains "$calls" $'workspace\037rename' "v1 unowned-parent refusal renamed a workspace"
  pass "Herdr spawn recovery: v1 flat fallback excludes the projected child"
}

# V2/v3 fallbacks select the exact journal parent id. The prior project-primary
# label migrates only on that id. Missing, foreign, or duplicate parent ids
# refuse before mutation.
test_v2_v3_flat_fallback_uses_exact_parent() {
  local version dir home log fake out status calls layout
  for version in 2 3; do
    dir="$TMP_ROOT/v$version-parent"; home="$dir/home"; mkdir -p "$home/state"
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"parent","label":"payments · primary"},{"workspace_id":"child","label":"└ invoice-check · p:AbCdEfGhIjKlMnOpQrStUv"}]}}'
    response "$dir" 2 '{"result":{"workspace":{"workspace_id":"parent","label":"payments · project"}}}'
    out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
      fmtest /srv/payments '' '' parent 'payments · primary') \
      || fail "v$version exact parent migration failed: $out"
    [ "$out" = parent ] || fail "v$version exact parent returned '$out'"
    calls=$(cat "$log")
    assert_contains "$calls" $'workspace\037rename\037parent\037payments · project' \
      "v$version did not migrate the exact old parent"
    assert_not_contains "$calls" $'rename\037child' "v$version fallback renamed its child"
  done

  dir="$TMP_ROOT/exact-secondmate-parent"; home="$dir/home"; mkdir -p "$home/state"
  printf 'research\n' > "$home/.fm-secondmate-home"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"parent","label":"research · second mate"},{"workspace_id":"child","label":"└ invoice-check · p:AbCdEfGhIjKlMnOpQrStUv"}]}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
    fmtest /srv/payments '' '' parent '') \
    || fail "second-mate child fallback could not select its exact stable parent"
  [ "$out" = parent ] || fail "second-mate exact parent returned '$out'"
  calls=$(cat "$log")
  assert_not_contains "$calls" $'workspace\037rename' \
    "second-mate exact parent was renamed during fallback"

  for layout in missing foreign duplicate; do
    dir="$TMP_ROOT/exact-parent-$layout"; home="$dir/home"; mkdir -p "$home/state"
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    case "$layout" in
      missing) response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"child","label":"└ invoice-check · p:AbCdEfGhIjKlMnOpQrStUv"}]}}' ;;
      foreign) response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"parent","label":"foreign"}]}}' ;;
      duplicate) response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"parent","label":"payments · primary"},{"workspace_id":"parent","label":"payments · primary"}]}}' ;;
    esac
    out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
      fmtest /srv/payments '' '' parent 'payments · primary' 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$layout exact parent was accepted"
    calls=$(cat "$log")
    assert_not_contains "$calls" $'workspace\037create' "$layout exact parent refusal created a workspace"
    assert_not_contains "$calls" $'workspace\037rename' "$layout exact parent refusal renamed a workspace"
  done
  pass "Herdr spawn recovery: v2/v3 fallback uses only the exact journal parent"
}

write_parent_record() {  # <home> <id> <workspace> <tab> <pane>
  local home=$1 id=$2 workspace=$3 tab=$4 pane=$5
  FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_parent_metadata_write "$1/state/.herdr-parent.meta" "$2" "$1" \
      fmtest "$3" "$4" "$5" "$2 · second mate" "$2 · second mate"
  ' "$ROOT" "$home" "$id" "$workspace" "$tab" "$pane"
}
write_secondmate_snapshot() {  # <dir> <first-call> <home> [agent-json] [pane-list]
  local dir=$1 first=$2 home=$3 agent=${4:-'{"error":{"code":"agent_not_found"}}'}
  local panes=${5:-'[{"workspace_id":"w1","pane_id":"w1:p1","tab_id":"w1:t1"}]'}
  response "$dir" "$first" '{"result":{"workspaces":[{"workspace_id":"w1","label":"research · second mate"}]}}'
  response "$dir" "$((first + 1))" '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"research · second mate"}]}}'
  response "$dir" "$((first + 2))" "{\"result\":{\"panes\":$panes}}"
  response "$dir" "$((first + 3))" "{\"result\":{\"pane\":{\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"pane_id\":\"w1:p1\",\"label\":\"research · second mate\",\"cwd\":\"$home\"}}}"
  response "$dir" "$((first + 4))" "$agent"
}

# A child-home parent record recovers only one exact one-pane no-agent
# second-mate husk. The old tab closes only after two identical snapshots and
# the republished parent record carries the replacement tuple.
test_secondmate_parent_only_recovery() {
  local dir home parent log fake out calls agent panes status mode good_parent task_meta helper
  dir="$TMP_ROOT/secondmate-parent"; home="$dir/home"; mkdir -p "$home/state"
  printf 'research\n' > "$home/.fm-secondmate-home"
  parent="$home/state/.herdr-parent.meta"
  write_parent_record "$home" research w1 w1:t1 w1:p1 || fail "could not write parent recovery record"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  write_secondmate_snapshot "$dir" 1 "$home"
  response "$dir" 6 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"research · second mate"}]}}'
  response "$dir" 7 '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
  response "$dir" 8 '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t2","label":"research · second mate"}}}'
  response "$dir" 9 '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p2","label":"research · second mate"}}}'
  write_secondmate_snapshot "$dir" 10 "$home"
  response "$dir" 15 '{}'
  response "$dir" 16 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t2","label":"research · second mate"}]}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_create_task \
    fmtest:w1 research secondmate "$home" '' '' "$parent" "$parent") \
    || fail "parent-only second-mate recovery failed: $out"
  [ "$out" = 'w1:t2 w1:p2' ] || fail "parent-only recovery returned '$out'"
  [ "$(grep '^herdr_tab_id=' "$parent")" = herdr_tab_id=w1:t2 ] \
    && [ "$(grep '^herdr_pane_id=' "$parent")" = herdr_pane_id=w1:p2 ] \
    || fail "parent record did not republish the replacement tuple"
  calls=$(cat "$log")
  assert_contains "$calls" $'tab\037close\037w1:t1' "parent-only recovery did not close the exact old tab"
  assert_not_contains "$calls" $'pane\037close\037w1:p1' "parent-only recovery closed the old pane directly"

  task_meta="$dir/primary.meta"
  printf '%s\n' \
    'backend=herdr' 'kind=secondmate' "project=$home" "home=$home" "worktree=$home" \
    'herdr_session=fmtest' 'herdr_session_display_label=Shared Herdr session' \
    'herdr_workspace_id=w1' 'herdr_tab_id=w1:t2' 'herdr_pane_id=w1:p2' \
    'display_label=research · second mate' 'herdr_workspace_label=research · second mate' \
    'herdr_tab_label=research · second mate' 'herdr_pane_label=research · second mate' > "$task_meta"
  helper=$(sed -n '/^spawn_herdr_secondmate_publications_match()/,/^}/p' "$ROOT/bin/fm-spawn.sh")
  FM_TEST_HELPER="$helper" FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    eval "$FM_TEST_HELPER"
    spawn_herdr_secondmate_publications_match "$1" "$2" research "$3"
  ' "$ROOT" "$task_meta" "$parent" "$home" \
    || fail "matching second-mate parent and primary publications were refused"
  perl -pi -e 's/^herdr_pane_id=.*/herdr_pane_id=foreign:pane/' "$task_meta"
  if FM_TEST_HELPER="$helper" FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    eval "$FM_TEST_HELPER"
    spawn_herdr_secondmate_publications_match "$1" "$2" research "$3"
  ' "$ROOT" "$task_meta" "$parent" "$home" >/dev/null 2>&1; then
    fail "mismatched second-mate parent and primary tuples were accepted"
  fi

  for mode in live-agent extra-pane foreign-tab missing-workspace missing-tab missing-pane; do
    dir="$TMP_ROOT/secondmate-$mode"; home="$dir/home"; mkdir -p "$home/state"
    printf 'research\n' > "$home/.fm-secondmate-home"
    parent="$home/state/.herdr-parent.meta"
    write_parent_record "$home" research w1 w1:t1 w1:p1 || fail "could not write $mode parent record"
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    agent='{"error":{"code":"agent_not_found"}}'
    panes='[{"workspace_id":"w1","pane_id":"w1:p1","tab_id":"w1:t1"}]'
    [ "$mode" != live-agent ] || agent='{"result":{"agent":{"agent_status":"idle"}}}'
    [ "$mode" != extra-pane ] || panes='[{"workspace_id":"w1","pane_id":"w1:p1","tab_id":"w1:t1"},{"workspace_id":"w1","pane_id":"w1:p9","tab_id":"w1:t1"}]'
    case "$mode" in
      missing-workspace)
        response "$dir" 1 '{"result":{"workspaces":[]}}'
        response "$dir" 2 '{"result":{"tabs":[]}}'
        response "$dir" 3 '{"error":{"code":"pane_not_found"}}'
        ;;
      missing-tab)
        response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"research · second mate"}]}}'
        response "$dir" 2 '{"result":{"tabs":[]}}'
        response "$dir" 3 '{"error":{"code":"pane_not_found"}}'
        ;;
      missing-pane)
        response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"research · second mate"}]}}'
        response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"research · second mate"}]}}'
        response "$dir" 3 '{"result":{"panes":[]}}'
        response "$dir" 4 '{"error":{"code":"pane_not_found"}}'
        ;;
      *) write_secondmate_snapshot "$dir" 1 "$home" "$agent" "$panes" ;;
    esac
    if [ "$mode" = foreign-tab ]; then
      response "$dir" 6 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"research · second mate"},{"workspace_id":"w1","tab_id":"foreign","label":"research · second mate"}]}}'
    fi
    out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_create_task \
      fmtest:w1 research secondmate "$home" '' '' "$parent" "$parent" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$mode second-mate parent recovery was accepted"
    calls=$(cat "$log")
    assert_not_contains "$calls" $'tab\037create' "$mode refusal created a replacement"
    assert_not_contains "$calls" $'tab\037close' "$mode refusal closed the old tab"
  done

  dir="$TMP_ROOT/parent-validator"; home="$dir/home"; mkdir -p "$home/state"
  printf 'research\n' > "$home/.fm-secondmate-home"
  parent="$home/state/.herdr-parent.meta"
  write_parent_record "$home" research w1 w1:t1 w1:p1 || fail "could not write validator parent record"
  good_parent="$dir/good-parent"; cp "$parent" "$good_parent"
  for mode in task marker kind home project worktree session label symlink; do
    rm -f "$parent"; cp "$good_parent" "$parent"
    case "$mode" in
      task) perl -pi -e 's/^task_id=.*/task_id=other/' "$parent" ;;
      marker) printf 'other\n' > "$home/.fm-secondmate-home" ;;
      kind) perl -pi -e 's/^kind=.*/kind=ship/' "$parent" ;;
      home) perl -pi -e 's#^home=.*#home=/foreign#' "$parent" ;;
      project) perl -pi -e 's#^project=.*#project=/foreign#' "$parent" ;;
      worktree) perl -pi -e 's#^worktree=.*#worktree=/foreign#' "$parent" ;;
      session) perl -pi -e 's/^herdr_session=.*/herdr_session=other/' "$parent" ;;
      label) perl -pi -e 's/^herdr_tab_label=.*/herdr_tab_label=foreign/' "$parent" ;;
      symlink) rm -f "$parent"; ln -s "$good_parent" "$parent" ;;
    esac
    if FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_parent_metadata_validate_recovery "$1" research "$2" "$2" "$2" fmtest' \
      "$ROOT" "$parent" "$home" >/dev/null 2>&1; then
      fail "$mode parent recovery record was accepted"
    fi
    printf 'research\n' > "$home/.fm-secondmate-home"
  done
  pass "Herdr spawn recovery: parent-only second mate replaces one exact no-agent husk"
}

# The spawn-owned classifier passes only proved prior-flat metadata onward and
# keeps projected child metadata as an explicit exclusion.
test_flat_retry_evidence_classification() {
  local dir home journal meta helper out token child HERDR_SES
  dir="$TMP_ROOT/flat-evidence"; home="$dir/home"; mkdir -p "$home/state"
  home=$(cd "$home" && pwd -P)
  HERDR_SES=fmtest
  export HERDR_SES
  token=AbCdEfGhIjKlMnOpQrStUv
  child="└ invoice-check · p:$token"
  helper=$(printf '%s\n' \
    "fm_backend_of_meta() { grep \"^backend=\" \"\$1\" 2>/dev/null | tail -1 | cut -d= -f2-; }"; \
    sed -n '/^herdr_projection_prepare_flat_evidence()/,/^}/p' "$ROOT/bin/fm-spawn.sh")
  journal="$home/state/invoice-check.herdr-presentation"
  printf '%s\n' \
    'version=2' 'task_id=invoice-check' "projection_id=$token" "home=$home" \
    'session=fmtest' 'workspace_id=child' 'tab_id=child:t1' 'pane_id=child:p1' \
    'parent_workspace_id=parent' 'parent_label=payments · primary' \
    "workspace_label=$child" 'task_label=fm-invoice-check' > "$journal"
  meta="$home/state/invoice-check.meta"
  write_task_meta "$meta" /srv/payments child child:t1 child:p1 "$child"
  out=$(FM_TEST_HELPER="$helper" FM_HOME="$home" FM_TEST_JOURNAL="$journal" FM_TEST_META="$meta" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      eval "$FM_TEST_HELPER"
      ID=invoice-check; HERDR_LABEL_HOME=$FM_HOME; PROJ_ABS=/srv/payments
      HERDR_HOME_LABEL="payments · project"
      herdr_projection_prepare_flat_evidence "$FM_TEST_JOURNAL" "$FM_TEST_META" || exit 1
      printf "%s|%s|%s|%s" "$HERDR_FLAT_TASK_META" "$HERDR_FLAT_EXCLUDED_META" \
        "$HERDR_FLAT_PARENT_WORKSPACE_ID" "$HERDR_FLAT_PARENT_PRIOR_LABEL"
    ' "$ROOT") || fail "v2 projected-child evidence classification failed"
  [ "$out" = "|$meta|parent|payments · primary" ] \
    || fail "v2 projected child was not excluded exactly: $out"
  perl -pi -e 's/^session=fmtest$/session=foreign/' "$journal"
  if FM_TEST_HELPER="$helper" FM_HOME="$home" FM_TEST_JOURNAL="$journal" FM_TEST_META="$meta" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      eval "$FM_TEST_HELPER"
      ID=invoice-check; HERDR_LABEL_HOME=$FM_HOME; PROJ_ABS=/srv/payments
      HERDR_HOME_LABEL="payments · project"
      herdr_projection_prepare_flat_evidence "$FM_TEST_JOURNAL" "$FM_TEST_META"
    ' "$ROOT" >/dev/null 2>&1; then
    fail "foreign v2 journal session granted flat-parent selection"
  fi
  perl -pi -e 's/^session=foreign$/session=fmtest/' "$journal"

  write_task_meta "$meta" /srv/payments parent parent:t1 parent:p1 'payments · project'
  out=$(FM_TEST_HELPER="$helper" FM_HOME="$home" FM_TEST_JOURNAL="$journal" FM_TEST_META="$meta" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      eval "$FM_TEST_HELPER"
      ID=invoice-check; HERDR_LABEL_HOME=$FM_HOME; PROJ_ABS=/srv/payments
      HERDR_HOME_LABEL="payments · project"
      herdr_projection_prepare_flat_evidence "$FM_TEST_JOURNAL" "$FM_TEST_META" || exit 1
      printf "%s|%s" "$HERDR_FLAT_TASK_META" "$HERDR_FLAT_EXCLUDED_META"
    ' "$ROOT") || fail "v2 prior-flat evidence classification failed"
  [ "$out" = "$meta|" ] || fail "v2 prior flat metadata lost exact-husk recovery: $out"

  printf '%s\n' 'version=1' 'task_id=invoice-check' "projection_id=$token" > "$journal"
  out=$(FM_TEST_HELPER="$helper" FM_HOME="$home" FM_TEST_JOURNAL="$journal" FM_TEST_META="$meta" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      eval "$FM_TEST_HELPER"
      ID=invoice-check; HERDR_LABEL_HOME=$FM_HOME; PROJ_ABS=/srv/payments
      HERDR_HOME_LABEL="payments · project"
      FM_BACKEND_HERDR_PROJECTION_TOKEN_MATCH_COUNT=1
      FM_BACKEND_HERDR_PROJECTION_UNIQUE_TOKEN_WORKSPACE_ID=child
      herdr_projection_prepare_flat_evidence "$FM_TEST_JOURNAL" "$FM_TEST_META" || exit 1
      printf "%s|%s" "$HERDR_FLAT_TASK_META" "$HERDR_FLAT_EXCLUDED_META"
    ' "$ROOT") || fail "v1 prior-flat evidence classification failed"
  [ "$out" = "$meta|" ] || fail "v1 prior flat metadata lost unique-child recovery: $out"
  pass "Herdr spawn recovery: projected and prior-flat metadata stay distinct"
}

# Keep the two evidence channels and publication order explicit in the real
# spawn owner. These assertions supplement the behavioral adapter fixtures.
test_spawn_wiring_keeps_recovery_channels_separate() {
  local source
  source=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$source" 'herdr_projection_prepare_flat_evidence' \
    "spawn has no projected-versus-flat evidence classifier"
  assert_contains "$source" "\"\$HERDR_FLAT_EXCLUDED_META\"" \
    "spawn does not pass projected metadata as an explicit exclusion"
  assert_contains "$source" "\"\$HERDR_PARENT_RECOVERY_META\"" \
    "spawn does not pass parent recovery separately from task metadata"
  assert_contains "$source" 'spawn_herdr_secondmate_publications_match' \
    "spawn does not compare parent and primary tuples before launch"
  pass "Herdr spawn recovery: flat, task, and parent evidence channels remain separate"
}

test_v1_flat_fallback_excludes_projected_child
test_v2_v3_flat_fallback_uses_exact_parent
test_secondmate_parent_only_recovery
test_flat_retry_evidence_classification
test_spawn_wiring_keeps_recovery_channels_separate
