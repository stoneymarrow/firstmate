#!/usr/bin/env bash
# Focused display-only Herdr label coverage for the six captain-facing surfaces.
# Every backend call is routed to a fake Herdr binary; no live session is read.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-display.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
CONFIG="$HOME_DIR/config"
WORKTREE="$TMP_ROOT/worktree"
FAKEBIN="$TMP_ROOT/fakebin"
LOG="$TMP_ROOT/herdr.log"
mkdir -p "$STATE" "$DATA" "$CONFIG" "$WORKTREE" "$FAKEBIN"
: > "$LOG"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3" ;; esac; }
assert_before() {  # <text> <left> <right> <message>
  local prefix
  case "$1" in *"$2"*"$3"*) return 0 ;; esac
  prefix=$4
  fail "$prefix"
}

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s' "${1:-}" >> "$FM_HERDR_DISPLAY_LOG"
for arg in "${@:2}"; do printf '\037%s' "$arg" >> "$FM_HERDR_DISPLAY_LOG"; done
printf '\n' >> "$FM_HERDR_DISPLAY_LOG"
case "${1:-}:${2:-}" in
  status:--json) printf '%s\n' '{"server":{"running":true}}' ;;
  pane:get) printf '%s\n' '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","label":"invoice-check · scout"}}}' ;;
  pane:read) printf '%s\n' 'raw-capture-bytes' ;;
  pane:send-keys)
    [ "${FM_HERDR_DISPLAY_SEND_FAIL:-0}" != 1 ] || exit 1
    printf '%s\n' '{}'
    ;;
  agent:get) printf '%s\n' '{"result":{"agent":{"agent_status":"idle","pid":4242}}}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$STATE/invoice-check.meta" <<EOF
window=shared:w1:p1
worktree=$WORKTREE
project=$ROOT
harness=pi
kind=scout
mode=no-mistakes
yolo=off
tasktmp=$TMP_ROOT/tasktmp
model=default
effort=default
backend=herdr
herdr_session=shared
herdr_session_display_label=Shared Herdr session
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
display_label=invoice-check · scout
herdr_workspace_label=firstmate · primary
herdr_tab_label=invoice-check · scout
herdr_pane_label=invoice-check · scout
EOF
printf 'paused: waiting for filing\n' > "$STATE/invoice-check.status"

run_env() {
  env PATH="$FAKEBIN:$PATH" FM_GATE_REFUSE_BYPASS=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects" FM_HERDR_DISPLAY_LOG="$LOG" "$@"
}

# Session-start keeps its complete digest while placing both display labels
# before the machine endpoint for Herdr metadata.
test_session_start_display() {
  local root out line
  root="$TMP_ROOT/session-root"
  mkdir -p "$root/bin" "$root/.pi/extensions"
  cp "$ROOT/bin/fm-session-start.sh" "$root/bin/fm-session-start.sh"
  cat > "$root/bin/fm-backend.sh" <<'SH'
fm_meta_get() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
fm_backend_of_meta() { local v; v=$(fm_meta_get "$1" backend); printf '%s' "${v:-tmux}"; }
fm_backend_target_of_meta() { fm_meta_get "$1" window; }
fm_backend_target_exists() { return 0; }
SH
  cat > "$root/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
fm_backlog_backend_manual() { return 1; }
SH
  for stub in fm-herdr-primary-labels.sh fm-herdr-session-cleanup.sh fm-bootstrap.sh fm-wake-drain.sh fm-supervision-instructions.sh fm-guard.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/$stub"
    chmod +x "$root/bin/$stub"
  done
  cat > "$root/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf 'lock acquired: harness pid 4242\n'
SH
  cat > "$root/bin/fm-harness.sh" <<'SH'
#!/usr/bin/env bash
printf 'unknown\n'
SH
  chmod +x "$root/bin/fm-lock.sh" "$root/bin/fm-harness.sh" "$root/bin/fm-session-start.sh"
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" "$root/bin/fm-session-start.sh") \
    || fail "session-start display fixture failed"
  line=$(printf '%s\n' "$out" | grep '^display: label=' | head -1)
  [ "$line" = 'display: label=invoice-check · scout session=Shared Herdr session target=shared:w1:p1' ] \
    || fail "session-start display line mismatch: $line"
  assert_before "$line" 'invoice-check · scout' 'shared:w1:p1' "session-start target preceded its label"
  assert_contains "$out" 'herdr_session_display_label=Shared Herdr session' "session-start lost raw metadata"
  assert_contains "$out" 'NEXT STEP' "session-start label owner truncated the remaining digest"
  pass "Herdr display: session start shows label and honest session alias before target"
}

# Snapshot adds Herdr-only label keys before the unchanged routing target, and
# fleet view renders the same order.
test_fleet_snapshot_and_view() {
  local snapshot keys view root
  snapshot=$(run_env "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "fleet snapshot fixture failed"
  [ "$(printf '%s' "$snapshot" | jq -r '.schema')" = 'fm-fleet-snapshot.v1' ] \
    || fail "fleet snapshot schema identity changed"
  [ "$(printf '%s' "$snapshot" | jq -r '.tasks[0].endpoint.target')" = 'shared:w1:p1' ] \
    || fail "fleet snapshot changed endpoint.target routing bytes"
  keys=$(printf '%s' "$snapshot" | jq -r '.tasks[0].endpoint | keys_unsorted | join(",")')
  case "$keys" in display_label,session_display_label,target,*) : ;; *) fail "snapshot label keys do not lead target: $keys" ;; esac
  [ "$(printf '%s' "$snapshot" | jq -r '.tasks[0].endpoint.display_label')" = 'invoice-check · scout' ] \
    && [ "$(printf '%s' "$snapshot" | jq -r '.tasks[0].endpoint.session_display_label')" = 'Shared Herdr session' ] \
    || fail "snapshot omitted Herdr display labels"

  root="$TMP_ROOT/view-root"; mkdir -p "$root/bin"
  cp "$ROOT/bin/fm-fleet-view.sh" "$root/bin/fm-fleet-view.sh"
  printf '%s\n' "$snapshot" > "$root/snapshot.json"
  cat > "$root/bin/fm-fleet-snapshot.sh" <<SH
#!/usr/bin/env bash
cat '$root/snapshot.json'
SH
  chmod +x "$root/bin/fm-fleet-view.sh" "$root/bin/fm-fleet-snapshot.sh"
  view=$("$root/bin/fm-fleet-view.sh") || fail "fleet view fixture failed"
  assert_before "$view" 'invoice-check · scout' 'shared:w1:p1' "fleet view target preceded its label"
  assert_contains "$view" 'Shared Herdr session' "fleet view omitted session display alias"
  pass "Herdr display: fleet snapshot keeps schema/target and fleet view renders labels first"
}

# Crew state keeps the leading state/source grammar and puts label then target
# before state detail.
test_crew_state_display() {
  local out expected
  out=$(run_env "$ROOT/bin/fm-crew-state.sh" invoice-check) \
    || fail "crew-state display fixture failed"
  expected='state: paused · source: status-log · label: invoice-check · scout · target: shared:w1:p1 · waiting for filing'
  [ "$out" = "$expected" ] || fail "crew-state display grammar mismatch: $out"
  pass "Herdr display: crew state preserves grammar and places label before target/detail"
}

# Send stays silent on success, reports label before target on failure, and
# routes the exact recorded target rather than either display field.
test_send_display_and_routing() {
  local root out status calls
  root="$TMP_ROOT/control-root"
  mkdir -p "$root"
  cp -R "$ROOT/bin" "$root/bin"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  : > "$LOG"
  out=$(env PATH="$FAKEBIN:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$root" FM_HERDR_DISPLAY_LOG="$LOG" \
    "$root/bin/fm-send.sh" invoice-check --key Enter 2>&1) \
    || fail "successful send fixture failed: $out"
  [ -z "$out" ] || fail "successful Herdr send was not silent: $out"
  calls=$(<"$LOG")
  assert_contains "$calls" $'pane\037send-keys\037w1:p1\037enter' "send did not route the exact recorded pane id"
  case "$calls" in *'invoice-check · scout'*|*'Shared Herdr session'*) fail "send routed through a display label" ;; esac

  : > "$LOG"
  out=$(env PATH="$FAKEBIN:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$root" FM_HERDR_DISPLAY_LOG="$LOG" \
    FM_HERDR_DISPLAY_SEND_FAIL=1 "$root/bin/fm-send.sh" invoice-check --key Escape 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "failed Herdr send reported success"
  assert_before "$out" "label 'invoice-check · scout'" "target 'shared:w1:p1'" "send error target preceded its label"
  assert_contains "$out" "session 'Shared Herdr session'" "send error omitted session display alias"
  pass "Herdr display: send is silent on success, label-first on errors, and routes exact ids"
}

# Piped peek is byte-identical capture; only an interactive stdout gains the
# label-first audit header.
test_peek_display_and_raw_pipe() {
  local root out tty_out calls
  root="$TMP_ROOT/control-root"
  : > "$LOG"
  out=$(env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_ROOT_OVERRIDE="$root" FM_HERDR_DISPLAY_LOG="$LOG" \
    "$root/bin/fm-peek.sh" invoice-check 5 2>/dev/null) \
    || fail "piped peek fixture failed"
  [ "$out" = 'raw-capture-bytes' ] || fail "piped peek changed raw capture bytes: $out"
  calls=$(<"$LOG")
  assert_contains "$calls" $'pane\037read\037w1:p1' "peek did not route the exact recorded pane id"
  case "$calls" in *'invoice-check · scout'*|*'Shared Herdr session'*) fail "peek routed through a display label" ;; esac

  command -v script >/dev/null 2>&1 || fail "script utility unavailable for interactive peek proof"
  tty_out=$(script -q /dev/null env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$root" FM_HERDR_DISPLAY_LOG="$LOG" \
    "$root/bin/fm-peek.sh" invoice-check 5 2>/dev/null | tr -d '\r') \
    || fail "interactive peek fixture failed"
  assert_before "$tty_out" 'label: invoice-check · scout' 'target: shared:w1:p1' "interactive peek target preceded its label"
  assert_contains "$tty_out" 'session: Shared Herdr session' "interactive peek omitted session display alias"
  assert_contains "$tty_out" 'raw-capture-bytes' "interactive peek omitted capture body"
  pass "Herdr display: piped peek stays raw and interactive peek adds a label-first header"
}

# Spawn's Herdr-only branch publishes through a same-directory temporary file,
# validates the complete record, then renames it. The non-Herdr destination
# remains the direct metadata path.
test_atomic_spawn_publication_shape() {
  local source mktemp_line validate_line move_line alias_line
  source=$(<"$ROOT/bin/fm-spawn.sh")
  mktemp_line=$(grep -Fn "HERDR_META_TEMP=\$(mktemp \"\$STATE/.\${ID}.meta.spawn.XXXXXX\")" "$ROOT/bin/fm-spawn.sh" | cut -d: -f1)
  validate_line=$(grep -Fn "fm_backend_herdr_metadata_validate_record \"\$HERDR_META_TEMP\"" "$ROOT/bin/fm-spawn.sh" | cut -d: -f1)
  move_line=$(grep -Fn "mv -f \"\$HERDR_META_TEMP\" \"\$STATE/\$ID.meta\"" "$ROOT/bin/fm-spawn.sh" | cut -d: -f1)
  alias_line=$(grep -Fn "echo \"herdr_session_display_label=\$(fm_backend_herdr_session_display_label)\"" "$ROOT/bin/fm-spawn.sh" | cut -d: -f1)
  [ -n "$mktemp_line" ] && [ -n "$validate_line" ] && [ -n "$move_line" ] && [ -n "$alias_line" ] \
    || fail "spawn atomic Herdr publication shape is incomplete"
  [ "$mktemp_line" -lt "$validate_line" ] && [ "$validate_line" -lt "$move_line" ] \
    || fail "spawn does not validate its same-directory temporary record before rename"
  assert_contains "$source" "META_OUTPUT=\"\$STATE/\$ID.meta\"" "spawn lost the unchanged direct non-Herdr destination"
  pass "Herdr metadata: new task record uses validated same-directory rename and carries session alias"
}

# A synthetic non-adapter record proves the new fields remain Herdr-only
# without invoking or naming any other backend implementation.
test_non_herdr_output_unchanged() {
  local meta snapshot keys state_line
  meta="$STATE/fixture.meta"
  cat > "$meta" <<EOF
window=fixture-target
worktree=$TMP_ROOT/absent-worktree
project=$ROOT
harness=pi
kind=scout
backend=fixture
EOF
  state_line=$(run_env "$ROOT/bin/fm-crew-state.sh" fixture) \
    || fail "synthetic non-Herdr crew-state fixture failed"
  [ "$state_line" = 'state: unknown · source: none · worktree gone (torn down?)' ] \
    || fail "non-Herdr crew-state output changed: $state_line"
  snapshot=$(run_env "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "synthetic non-Herdr snapshot fixture failed"
  keys=$(printf '%s' "$snapshot" | jq -r '.tasks[] | select(.id == "fixture") | .endpoint | keys_unsorted | join(",")')
  [ "$keys" = 'target,exists,agent_alive,status,observed_at,freshness' ] \
    || fail "non-Herdr endpoint gained display keys or changed key order: $keys"
  [ "$(printf '%s' "$snapshot" | jq -r '.tasks[] | select(.id == "fixture") | .endpoint.target')" = fixture-target ] \
    || fail "non-Herdr endpoint target changed"
  rm -f "$meta"
  pass "Display isolation: synthetic non-Herdr state and snapshot output remain unchanged"
}

test_session_start_display
test_fleet_snapshot_and_view
test_non_herdr_output_unchanged
test_crew_state_display
test_send_display_and_routing
test_peek_display_and_raw_pipe
test_atomic_spawn_publication_shape
