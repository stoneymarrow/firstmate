#!/usr/bin/env bash
# tests/fm-backend-herdr-workspace-per-home-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for the P3 "workspace-per-home" pass (AGENTS.md
# task herdr-sm-spaces-k4). Drives the REAL bin/fm-spawn.sh and
# bin/fm-teardown.sh (not just adapter primitives), because the requirement
# under test - a --secondmate spawn's tab landing in the secondmate's OWN
# herdr workspace, and a crewmate spawned FROM a secondmate home landing there
# too - only exists at fm-spawn.sh's own home-shadowing logic (the herdr case
# arm) and at fm_backend_herdr_workspace_label's FM_HOME read; neither is
# exercised by the adapter-primitive smoke test.
#
# Mirrors tests/fm-backend-autodetect-smoke.test.sh's isolated-session
# convention: a private throwaway HERDR_SESSION (never the captain's
# default), scratch FM_HOME(s), and scratch local-only projects.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop`.
#
# Covers readable primary, worker, and second-mate labels; two project-owned
# primary workspaces without label churn; exact metadata-owned discovery after
# one guarded restart; and the existing exact teardown safety.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}
assert_not_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
    *) : ;;
  esac
}
meta_field_exact() {  # <metadata-file> <field>
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^$2=" "$1" | cut -d= -f2-
}
workspace_label() {  # <workspace-id>
  herdr workspace list --session "$SESSION" 2>&1 \
    | jq -r --arg id "$1" '.result.workspaces[]? | select(.workspace_id == $id) | .label'
}
tab_label() {  # <workspace-id> <tab-id>
  herdr tab list --workspace "$1" --session "$SESSION" 2>&1 \
    | jq -r --arg id "$2" '.result.tabs[]? | select(.tab_id == $id) | .label'
}
pane_label() {  # <pane-id>
  herdr pane get "$1" --session "$SESSION" 2>&1 | jq -r '.result.pane.label // empty'
}
assert_labels() {  # <description> <meta> <workspace> <tab> <pane> <workspace-label> <task-label>
  local description=$1 meta=$2 wsid=$3 tab=$4 pane=$5 workspace_expected=$6 task_expected=$7
  [ "$(meta_field_exact "$meta" herdr_workspace_label)" = "$workspace_expected" ] \
    || fail "$description metadata workspace label mismatch"
  [ "$(meta_field_exact "$meta" display_label)" = "$task_expected" ] \
    || fail "$description metadata display label mismatch"
  [ "$(meta_field_exact "$meta" herdr_tab_label)" = "$task_expected" ] \
    || fail "$description metadata tab label mismatch"
  [ "$(meta_field_exact "$meta" herdr_pane_label)" = "$task_expected" ] \
    || fail "$description metadata pane label mismatch"
  [ "$(workspace_label "$wsid")" = "$workspace_expected" ] \
    || fail "$description live workspace label mismatch"
  [ "$(tab_label "$wsid" "$tab")" = "$task_expected" ] \
    || fail "$description live tab label mismatch"
  [ "$(pane_label "$pane")" = "$task_expected" ] \
    || fail "$description live pane label mismatch"
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# TMP_ROOT is physically resolved (mktemp -d "$(pwd -P)"-relative) for the same
# low-noise scratch fixture shape used by
# tests/fm-backend-autodetect-smoke.test.sh.
# fm-spawn no longer needs this as a symlink workaround: fm-spawn-symlink-guard-s8
# canonicalized project and backend cwd comparisons in the worktree-discovery
# poll.
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-e2e.XXXXXX")
SESSION="fm-lab-herdr-e2e-$$"
export HERDR_SESSION="$SESSION"
WORKER_ID=invoice-check
SECOND_WORKER_ID=stock-check
SECOND_MATE_ID=research
SM_WORKER_ID=source-check
WT1=; WT2=; WT3=
cleanup_all() {
  [ -n "$WT1" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT1" >/dev/null 2>&1
  [ -n "$WT2" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT2" >/dev/null 2>&1
  [ -n "$WT3" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT3" >/dev/null 2>&1
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- scratch world: a primary-shaped home, a secondmate-shaped home, three projects ---

PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data/$WORKER_ID" \
  "$PRIMARY_HOME/data/$SECOND_WORKER_ID" "$PRIMARY_HOME/config"
printf 'trivial e2e primary crewmate brief: nothing to do.\n' > "$PRIMARY_HOME/data/$WORKER_ID/brief.md"
printf 'trivial e2e second primary-project brief: nothing to do.\n' > "$PRIMARY_HOME/data/$SECOND_WORKER_ID/brief.md"

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/$SM_WORKER_ID" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf '%s\n' "$SECOND_MATE_ID" > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"
printf 'trivial e2e secondmate-owned crewmate brief: nothing to do.\n' > "$SM_HOME/data/$SM_WORKER_ID/brief.md"

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

PROJ1="$TMP_ROOT/payments"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/research-notes"; make_scratch_project "$PROJ2"
PROJ3="$TMP_ROOT/inventory"; make_scratch_project "$PROJ3"

# --- 1. two primary projects get stable readable workspaces ----------------

CM1_OUT="$TMP_ROOT/cm1.out"; CM1_ERR="$TMP_ROOT/cm1.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$WORKER_ID" "$PROJ1" "sh -c 'echo primary-crew-ok'" --backend herdr \
  >"$CM1_OUT" 2>"$CM1_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "primary worker spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$CM1_OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$CM1_ERR")"
CM1_META="$PRIMARY_HOME/state/$WORKER_ID.meta"
WT1=$(meta_field_exact "$CM1_META" worktree) || fail "$WORKER_ID metadata has no exact worktree"
CM1_WSID=$(meta_field_exact "$CM1_META" herdr_workspace_id) || fail "$WORKER_ID metadata has no exact workspace"
CM1_TAB=$(meta_field_exact "$CM1_META" herdr_tab_id) || fail "$WORKER_ID metadata has no exact tab"
CM1_PANE=$(meta_field_exact "$CM1_META" herdr_pane_id) || fail "$WORKER_ID metadata has no exact pane"
assert_labels "$WORKER_ID" "$CM1_META" "$CM1_WSID" "$CM1_TAB" "$CM1_PANE" \
  'payments · primary' 'invoice-check · worker'
sleep 1
CM1_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM1_PANE" 30) \
  || fail "capture failed on the primary worker pane"
assert_contains_local "$CM1_CAPTURE" "primary-crew-ok" \
  "primary worker labels passed but its raw launch command did not run"

CM3_OUT="$TMP_ROOT/cm3.out"; CM3_ERR="$TMP_ROOT/cm3.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$SECOND_WORKER_ID" "$PROJ3" "sh -c 'echo second-primary-ok'" --backend herdr \
  >"$CM3_OUT" 2>"$CM3_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "second primary-project spawn failed"$'\n'"$(cat "$CM3_ERR")"
CM3_META="$PRIMARY_HOME/state/$SECOND_WORKER_ID.meta"
WT3=$(meta_field_exact "$CM3_META" worktree) || fail "$SECOND_WORKER_ID metadata has no exact worktree"
CM3_WSID=$(meta_field_exact "$CM3_META" herdr_workspace_id) || fail "$SECOND_WORKER_ID metadata has no exact workspace"
CM3_TAB=$(meta_field_exact "$CM3_META" herdr_tab_id) || fail "$SECOND_WORKER_ID metadata has no exact tab"
CM3_PANE=$(meta_field_exact "$CM3_META" herdr_pane_id) || fail "$SECOND_WORKER_ID metadata has no exact pane"
[ "$CM3_WSID" != "$CM1_WSID" ] || fail "two primary projects shared one workspace"
assert_labels "$SECOND_WORKER_ID" "$CM3_META" "$CM3_WSID" "$CM3_TAB" "$CM3_PANE" \
  'inventory · primary' 'stock-check · worker'
assert_labels "$WORKER_ID after project two" "$CM1_META" "$CM1_WSID" "$CM1_TAB" "$CM1_PANE" \
  'payments · primary' 'invoice-check · worker'
pass "real herdr E2E: two primary projects coexist without label churn"

# --- 2. a second mate and its worker share one stable marked workspace -----

SM_OUT="$TMP_ROOT/sm.out"; SM_ERR="$TMP_ROOT/sm.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$SECOND_MATE_ID" "$SM_HOME" "sh -c 'echo secondmate-launch-ok'" --secondmate --backend herdr \
  >"$SM_OUT" 2>"$SM_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "second-mate spawn failed"$'\n'"$(cat "$SM_ERR")"
SM_META="$PRIMARY_HOME/state/$SECOND_MATE_ID.meta"
assert_contains_local "$(cat "$SM_META")" "home=$SM_HOME" "second-mate metadata does not record its home"
SM_WSID=$(meta_field_exact "$SM_META" herdr_workspace_id) || fail "second-mate metadata has no exact workspace"
SM_TAB=$(meta_field_exact "$SM_META" herdr_tab_id) || fail "second-mate metadata has no exact tab"
SM_PANE=$(meta_field_exact "$SM_META" herdr_pane_id) || fail "second-mate metadata has no exact pane"
assert_labels "second mate" "$SM_META" "$SM_WSID" "$SM_TAB" "$SM_PANE" \
  "$SECOND_MATE_ID · second mate" "$SECOND_MATE_ID · second mate"

CM2_OUT="$TMP_ROOT/cm2.out"; CM2_ERR="$TMP_ROOT/cm2.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$SM_WORKER_ID" "$PROJ2" "sh -c 'echo sm-crew-ok'" --backend herdr \
  >"$CM2_OUT" 2>"$CM2_ERR"
rc=$?
[ "$rc" -eq 0 ] || fail "second-mate worker spawn failed"$'\n'"$(cat "$CM2_ERR")"
CM2_META="$SM_HOME/state/$SM_WORKER_ID.meta"
WT2=$(meta_field_exact "$CM2_META" worktree) || fail "$SM_WORKER_ID metadata has no exact worktree"
CM2_WSID=$(meta_field_exact "$CM2_META" herdr_workspace_id) || fail "$SM_WORKER_ID metadata has no exact workspace"
CM2_TAB=$(meta_field_exact "$CM2_META" herdr_tab_id) || fail "$SM_WORKER_ID metadata has no exact tab"
CM2_PANE=$(meta_field_exact "$CM2_META" herdr_pane_id) || fail "$SM_WORKER_ID metadata has no exact pane"
[ "$CM2_WSID" = "$SM_WSID" ] || fail "second-mate worker left the stable marked workspace"
assert_labels "second-mate worker" "$CM2_META" "$CM2_WSID" "$CM2_TAB" "$CM2_PANE" \
  "$SECOND_MATE_ID · second mate" 'source-check · worker'
sleep 1
CM2_CAPTURE=$(fm_backend_herdr_capture "$SESSION:$CM2_PANE" 30) \
  || fail "capture failed on the marked-home worker pane"
assert_contains_local "$CM2_CAPTURE" "sm-crew-ok" \
  "marked-home worker labels passed but its raw launch command did not run"
pass "real herdr E2E: a marked second-mate workspace stays stable for its worker"

# --- 3. one guarded restart preserves labels and exact discovery -----------

fm_herdr_lab_stop "$SESSION" >/dev/null 2>&1 || fail "isolated Herdr restart stop failed"
fm_backend_herdr_server_ensure "$SESSION" || fail "isolated Herdr restart failed"
assert_labels "$WORKER_ID after restart" "$CM1_META" "$CM1_WSID" "$CM1_TAB" "$CM1_PANE" \
  'payments · primary' 'invoice-check · worker'
assert_labels "$SECOND_WORKER_ID after restart" "$CM3_META" "$CM3_WSID" "$CM3_TAB" "$CM3_PANE" \
  'inventory · primary' 'stock-check · worker'
assert_labels "second mate after restart" "$SM_META" "$SM_WSID" "$SM_TAB" "$SM_PANE" \
  "$SECOND_MATE_ID · second mate" "$SECOND_MATE_ID · second mate"

PRIMARY_LIVE=$(FM_HOME="$PRIMARY_HOME" fm_backend_herdr_list_live "$SESSION")
assert_contains_local "$PRIMARY_LIVE" "$SESSION:$CM1_PANE"$'\t''invoice-check · worker' "primary list_live missed its first exact tuple"
assert_contains_local "$PRIMARY_LIVE" "$SESSION:$CM3_PANE"$'\t''stock-check · worker' "primary list_live missed its second exact tuple"
assert_contains_local "$PRIMARY_LIVE" "$SESSION:$SM_PANE"$'\t'"$SECOND_MATE_ID · second mate" "primary list_live missed its exact second-mate tuple"
assert_not_contains_local "$PRIMARY_LIVE" "$SESSION:$CM2_PANE" "primary list_live inferred a child owned by another home"
SM_LIVE=$(FM_HOME="$SM_HOME" fm_backend_herdr_list_live "$SESSION")
[ "$SM_LIVE" = "$SESSION:$CM2_PANE"$'\t''source-check · worker' ] \
  || fail "second-mate list_live was not limited to its exact local child: $SM_LIVE"
pass "real herdr E2E: guarded restart keeps exact readable labels and metadata-owned discovery"

# --- 4. teardown closes the RIGHT tab, and no other ------------------------

TD1_OUT="$TMP_ROOT/td1.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" "$WORKER_ID" >"$TD1_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for $WORKER_ID"$'\n'"$(cat "$TD1_OUT")"
[ -f "$CM1_META" ] && fail "fm-teardown.sh did not remove $WORKER_ID metadata"
if herdr pane get "$CM1_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close $WORKER_ID pane"
fi
if ! herdr pane get "$CM3_PANE" --session "$SESSION" >/dev/null 2>&1 \
   || ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1 \
   || ! herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down $WORKER_ID closed another exact Herdr endpoint"
fi
WT1=
pass "real herdr E2E: first primary teardown closes only its exact tab"

TD3_OUT="$TMP_ROOT/td3.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" FM_DATA_OVERRIDE="$PRIMARY_HOME/data" \
  FM_CONFIG_OVERRIDE="$PRIMARY_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" "$SECOND_WORKER_ID" >"$TD3_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for $SECOND_WORKER_ID"$'\n'"$(cat "$TD3_OUT")"
[ -f "$CM3_META" ] && fail "fm-teardown.sh did not remove $SECOND_WORKER_ID metadata"
if herdr pane get "$CM3_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close $SECOND_WORKER_ID pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1 \
   || ! herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down $SECOND_WORKER_ID closed a second-mate endpoint"
fi
WT3=

TD2_OUT="$TMP_ROOT/td2.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$SM_HOME/state" FM_DATA_OVERRIDE="$SM_HOME/data" \
  FM_CONFIG_OVERRIDE="$SM_HOME/config" \
  "$ROOT/bin/fm-teardown.sh" "$SM_WORKER_ID" >"$TD2_OUT" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fm-teardown.sh failed for $SM_WORKER_ID"$'\n'"$(cat "$TD2_OUT")"
[ -f "$CM2_META" ] && fail "fm-teardown.sh did not remove $SM_WORKER_ID metadata"
if herdr pane get "$CM2_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close $SM_WORKER_ID pane"
fi
if ! herdr pane get "$SM_PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "tearing down $SM_WORKER_ID closed the second mate's exact pane"
fi
WT2=
pass "real herdr E2E: second-mate worker teardown closes only its exact tab"

fm_backend_herdr_kill "$SESSION:$SM_PANE"

cleanup_all
trap - EXIT
