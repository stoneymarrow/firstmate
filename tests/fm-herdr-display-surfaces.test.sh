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
  local snapshot view_snapshot keys view root
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
  view_snapshot=$snapshot
  printf '%s' "$snapshot" | jq -e '
    .tasks[0].current_state.state == "paused"
    and .tasks[0].current_state.source == "status-log"
    and .tasks[0].current_state.detail == "waiting for filing"
    and .tasks[0].current_state.raw ==
      "state: paused · source: status-log · label: invoice-check · scout · target: shared:w1:p1 · waiting for filing"
  ' >/dev/null || fail "fleet snapshot retained Herdr display fields inside state detail"

  cp "$STATE/invoice-check.meta" "$TMP_ROOT/invoice-check.meta.saved"
  printf 'paused: waiting · for filing\n' > "$STATE/invoice-check.status"
  perl -pi -e 's/^display_label=.*$/display_label=-/' "$STATE/invoice-check.meta"
  snapshot=$(run_env "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "fleet snapshot display-label dash fixture failed"
  [ "$(printf '%s' "$snapshot" | jq -r '.tasks[0].current_state.detail')" = 'waiting · for filing' ] \
    || fail "state detail containing the display separator was truncated"
  [ "$(printf '%s' "$snapshot" | jq -r '.tasks[0].current_state.raw')" = \
    'state: paused · source: status-log · label: - · target: shared:w1:p1 · waiting · for filing' ] \
    || fail "display-label dash or raw state bytes changed"
  mv "$TMP_ROOT/invoice-check.meta.saved" "$STATE/invoice-check.meta"
  printf 'paused: waiting for filing\n' > "$STATE/invoice-check.status"

  root="$TMP_ROOT/view-root"; mkdir -p "$root/bin"
  cp "$ROOT/bin/fm-fleet-view.sh" "$root/bin/fm-fleet-view.sh"
  printf '%s\n' "$view_snapshot" > "$root/snapshot.json"
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

# Malformed optional display grammar stays in detail rather than losing bytes;
# an unknown line keeps its raw fallback and unknown state fields.
test_fleet_state_detail_malformed_fallback() {
  local helper root raw parsed meta
  helper=$(sed -n '/^crew_state_meta_is_exact_herdr()/,/^status_event_json()/p' \
    "$ROOT/bin/fm-fleet-snapshot.sh" | sed '$d')
  [ -n "$helper" ] || fail "fleet state parser functions are missing"
  root="$TMP_ROOT/state-parser-root"; mkdir -p "$root/bin" "$root/state"
  meta="$root/state/fixture.meta"
  cat > "$root/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_CREW_RAW"
SH
  chmod +x "$root/bin/fm-crew-state.sh"
  printf '%s\n' 'backend=herdr' 'herdr_session=shared' 'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p1' > "$meta"
  raw='state: idle · source: agent-state · label: invoice-check · worker · target: shared:w1:p1'
  parsed=$(FM_TEST_HELPER="$helper" FM_TEST_CREW_RAW="$raw" FM_TEST_ROOT="$root" FM_TEST_REPO="$ROOT" \
    bash -c '
      FM_ROOT=$FM_TEST_REPO; FM_HOME=$FM_TEST_ROOT; STATE=$FM_TEST_ROOT/state
      DATA=$FM_TEST_ROOT; PROJECTS=$FM_TEST_ROOT; CONFIG=$FM_TEST_ROOT
      . "$FM_TEST_REPO/bin/fm-backend.sh"
      SCRIPT_DIR=$FM_TEST_ROOT/bin
      eval "$FM_TEST_HELPER"
      crew_state_json fixture
    ') || fail "exact no-detail state parser fixture failed"
  printf '%s' "$parsed" | jq -e \
    '.state == "idle" and .source == "agent-state" and .detail == ""' >/dev/null \
    || fail "exact Herdr no-detail state retained display fields as detail"
  pass "Herdr display: exact no-detail state strips display fields to empty detail"

  raw='state: paused · source: status-log · label:  · target: shared:w1:p1 · waiting for filing'
  parsed=$(FM_TEST_HELPER="$helper" FM_TEST_CREW_RAW="$raw" FM_TEST_ROOT="$root" FM_TEST_REPO="$ROOT" \
    bash -c '
      FM_ROOT=$FM_TEST_REPO; FM_HOME=$FM_TEST_ROOT; STATE=$FM_TEST_ROOT/state
      DATA=$FM_TEST_ROOT; PROJECTS=$FM_TEST_ROOT; CONFIG=$FM_TEST_ROOT
      . "$FM_TEST_REPO/bin/fm-backend.sh"
      SCRIPT_DIR=$FM_TEST_ROOT/bin
      eval "$FM_TEST_HELPER"
      crew_state_json fixture
    ') || fail "malformed state-detail parser fixture failed"
  [ "$(printf '%s' "$parsed" | jq -r '.detail')" = \
    'label:  · target: shared:w1:p1 · waiting for filing' ] \
    || fail "malformed display fields were stripped from fallback detail"

  printf '%s\n' 'window=fixture-target' 'backend=fixture' > "$meta"
  raw='state: paused · source: status-log · label: customer · target: quarter · waiting'
  parsed=$(FM_TEST_HELPER="$helper" FM_TEST_CREW_RAW="$raw" FM_TEST_ROOT="$root" FM_TEST_REPO="$ROOT" \
    bash -c '
      FM_ROOT=$FM_TEST_REPO; FM_HOME=$FM_TEST_ROOT; STATE=$FM_TEST_ROOT/state
      DATA=$FM_TEST_ROOT; PROJECTS=$FM_TEST_ROOT; CONFIG=$FM_TEST_ROOT
      . "$FM_TEST_REPO/bin/fm-backend.sh"
      SCRIPT_DIR=$FM_TEST_ROOT/bin
      eval "$FM_TEST_HELPER"
      crew_state_json fixture
    ') || fail "non-Herdr display-shaped detail fixture failed"
  [ "$(printf '%s' "$parsed" | jq -r '.detail')" = \
    'label: customer · target: quarter · waiting' ] \
    || fail "non-Herdr display-shaped detail lost bytes"

  printf '%s\n' 'backend=herdr' 'herdr_session=shared' > "$meta"
  parsed=$(FM_TEST_HELPER="$helper" FM_TEST_CREW_RAW="$raw" FM_TEST_ROOT="$root" FM_TEST_REPO="$ROOT" \
    bash -c '
      FM_ROOT=$FM_TEST_REPO; FM_HOME=$FM_TEST_ROOT; STATE=$FM_TEST_ROOT/state
      DATA=$FM_TEST_ROOT; PROJECTS=$FM_TEST_ROOT; CONFIG=$FM_TEST_ROOT
      . "$FM_TEST_REPO/bin/fm-backend.sh"
      SCRIPT_DIR=$FM_TEST_ROOT/bin
      eval "$FM_TEST_HELPER"
      crew_state_json fixture
    ') || fail "malformed Herdr display-shaped detail fixture failed"
  [ "$(printf '%s' "$parsed" | jq -r '.detail')" = \
    'label: customer · target: quarter · waiting' ] \
    || fail "malformed Herdr metadata authorized display-prefix stripping"

  raw='unexpected crew state bytes'
  parsed=$(FM_TEST_HELPER="$helper" FM_TEST_CREW_RAW="$raw" FM_TEST_ROOT="$root" FM_TEST_REPO="$ROOT" \
    bash -c '
      FM_ROOT=$FM_TEST_REPO; FM_HOME=$FM_TEST_ROOT; STATE=$FM_TEST_ROOT/state
      DATA=$FM_TEST_ROOT; PROJECTS=$FM_TEST_ROOT; CONFIG=$FM_TEST_ROOT
      . "$FM_TEST_REPO/bin/fm-backend.sh"
      SCRIPT_DIR=$FM_TEST_ROOT/bin
      eval "$FM_TEST_HELPER"
      crew_state_json fixture
    ') || fail "unknown state-line parser fixture failed"
  printf '%s' "$parsed" | jq -e \
    '.state == "unknown" and .source == "none" and .detail == "" and .raw == "unexpected crew state bytes"' \
    >/dev/null || fail "unknown state line changed its legacy fallback fields"
  pass "Herdr display: malformed, non-Herdr, and unknown crew-state shapes keep fallback bytes"
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

# The extracted spawn publisher is exercised with a blocking PATH-injected mv.
# A concurrent reader sees only the old complete record until rename, then the
# complete fresh-spawn candidate. Unsafe destinations, incomplete schema,
# validation or ordinary rename failure, and a false-success rename cannot
# report publish. A copy-and-lie substitute may change public bytes before the
# verifier refuses, so this fixture does not claim rollback against it.
test_atomic_metadata_publication_behavior() {
  local dir fake helper public candidate old_bytes pid out status source symlink_target
  dir="$TMP_ROOT/atomic-publication"; fake="$dir/bin"; mkdir -p "$fake" "$dir/state"
  helper=$(sed -n '/^spawn_herdr_metadata_field_once()/,/^spawn_herdr_secondmate_publications_match()/p' \
    "$ROOT/bin/fm-spawn.sh" | sed '$d')
  [ -n "$helper" ] || fail "spawn Herdr publication helpers are missing"
  cat > "$fake/mv" <<'SH'
#!/usr/bin/env bash
set -u
case "${FM_TEST_MV_MODE:-pass}" in
  block)
    : > "$FM_TEST_MV_READY"
    while [ ! -e "$FM_TEST_MV_RELEASE" ]; do sleep 0.02; done
    exec /bin/mv "$@"
    ;;
  fail) exit 1 ;;
  noop) exit 0 ;;
  copy)
    /bin/cp "${2:-}" "${3:-}"
    exit 0
    ;;
  symlink)
    candidate=${2:-}
    public=${3:-}
    /bin/rm -f "$candidate" "$public"
    /bin/ln -s "$FM_TEST_MV_SYMLINK_TARGET" "$public"
    ;;
  *) exec /bin/mv "$@" ;;
esac
SH
  chmod +x "$fake/mv"
  public="$dir/state/task.meta"
  candidate="$dir/state/.task.meta.spawn.candidate"

  write_complete_candidate() {
    cat > "$candidate" <<'EOF'
window=shared:w1:p1
worktree=/tmp/worktree
project=/tmp/project
harness=pi
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-task
model=default
effort=default
backend=herdr
herdr_session=shared
herdr_session_display_label=Shared Herdr session
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
display_label=task · worker
herdr_workspace_label=project · project
herdr_tab_label=task · worker
herdr_pane_label=task · worker
EOF
  }

  printf '%s\n' 'old=complete' > "$public"
  old_bytes=$(cat "$public")
  write_complete_candidate
  (
    PATH="$fake:$PATH" FM_HOME="$HOME_DIR" FM_TEST_MV_MODE=block \
      FM_TEST_MV_READY="$dir/ready" FM_TEST_MV_RELEASE="$dir/release" \
      FM_TEST_HELPER="$helper" FM_TEST_CANDIDATE="$candidate" FM_TEST_PUBLIC="$public" \
      bash -c '. "$0/bin/backends/herdr.sh"; eval "$FM_TEST_HELPER"; spawn_herdr_metadata_publish "$FM_TEST_CANDIDATE" "$FM_TEST_PUBLIC"' "$ROOT"
  ) &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$dir/ready" ] && break; sleep 0.02; done
  [ -e "$dir/ready" ] || fail "blocking rename did not reach the publication boundary"
  [ "$(cat "$public")" = "$old_bytes" ] || fail "reader observed candidate bytes before atomic rename"
  : > "$dir/release"
  wait "$pid" || fail "released atomic rename failed"
  grep -qx 'herdr_pane_id=w1:p1' "$public" || fail "reader did not observe the complete candidate after rename"
  [ "$(grep -c '^backend=herdr$' "$public")" = 1 ] || fail "published candidate was incomplete"

  rm -f "$public"
  write_complete_candidate
  PATH="$fake:$PATH" FM_HOME="$HOME_DIR" FM_TEST_HELPER="$helper" \
    FM_TEST_CANDIDATE="$candidate" FM_TEST_PUBLIC="$public" \
    bash -c '. "$0/bin/backends/herdr.sh"; eval "$FM_TEST_HELPER"; spawn_herdr_metadata_publish "$FM_TEST_CANDIDATE" "$FM_TEST_PUBLIC"' "$ROOT" \
    || fail "absent Herdr public destination was refused"
  [ -f "$public" ] && [ ! -L "$public" ] || fail "absent destination did not publish one regular file"

  rm -f "$public" "$candidate"
  mkdir "$public"
  write_complete_candidate
  out=$(PATH="$fake:$PATH" FM_HOME="$HOME_DIR" FM_TEST_HELPER="$helper" \
    FM_TEST_CANDIDATE="$candidate" FM_TEST_PUBLIC="$public" \
    bash -c '. "$0/bin/backends/herdr.sh"; eval "$FM_TEST_HELPER"; spawn_herdr_metadata_publish "$FM_TEST_CANDIDATE" "$FM_TEST_PUBLIC"' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "directory Herdr public destination was accepted"
  [ -f "$candidate" ] && [ ! -e "$public/$(basename "$candidate")" ] \
    || fail "directory refusal moved the candidate inside the destination"
  rmdir "$public"

  symlink_target="$dir/state/symlink-target"
  printf 'old=target\n' > "$symlink_target"
  ln -s "$symlink_target" "$public"
  out=$(PATH="$fake:$PATH" FM_HOME="$HOME_DIR" FM_TEST_HELPER="$helper" \
    FM_TEST_CANDIDATE="$candidate" FM_TEST_PUBLIC="$public" \
    bash -c '. "$0/bin/backends/herdr.sh"; eval "$FM_TEST_HELPER"; spawn_herdr_metadata_publish "$FM_TEST_CANDIDATE" "$FM_TEST_PUBLIC"' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "symlink Herdr public destination was accepted"
  [ -L "$public" ] && [ -f "$candidate" ] || fail "symlink destination refusal changed either path"
  rm -f "$public"

  printf '%s\n' 'old=complete' > "$public"
  cat > "$candidate" <<'EOF'
window=shared:w1:p1
worktree=/tmp/worktree
project=/tmp/project
harness=pi
kind=ship
backend=herdr
herdr_session=shared
herdr_session_display_label=Shared Herdr session
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
EOF
  out=$(PATH="$fake:$PATH" FM_HOME="$HOME_DIR" FM_TEST_HELPER="$helper" \
    FM_TEST_CANDIDATE="$candidate" FM_TEST_PUBLIC="$public" \
    bash -c '. "$0/bin/backends/herdr.sh"; eval "$FM_TEST_HELPER"; spawn_herdr_metadata_publish "$FM_TEST_CANDIDATE" "$FM_TEST_PUBLIC"' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "identity-complete but truncated fresh-spawn candidate was published"
  [ "$(cat "$public")" = 'old=complete' ] || fail "truncated schema validation changed public metadata"

  printf '%s\n' 'backend=herdr' > "$candidate"
  out=$(PATH="$fake:$PATH" FM_HOME="$HOME_DIR" FM_TEST_HELPER="$helper" \
    FM_TEST_CANDIDATE="$candidate" FM_TEST_PUBLIC="$public" \
    bash -c '. "$0/bin/backends/herdr.sh"; eval "$FM_TEST_HELPER"; spawn_herdr_metadata_publish "$FM_TEST_CANDIDATE" "$FM_TEST_PUBLIC"' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed Herdr candidate was published"
  [ "$(cat "$public")" = 'old=complete' ] || fail "malformed validation changed public metadata"

  write_complete_candidate
  out=$(PATH="$fake:$PATH" FM_HOME="$HOME_DIR" FM_TEST_MV_MODE=fail \
    FM_TEST_HELPER="$helper" FM_TEST_CANDIDATE="$candidate" FM_TEST_PUBLIC="$public" \
    bash -c '. "$0/bin/backends/herdr.sh"; eval "$FM_TEST_HELPER"; spawn_herdr_metadata_publish "$FM_TEST_CANDIDATE" "$FM_TEST_PUBLIC"' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "injected rename failure reported publication success"
  [ "$(cat "$public")" = 'old=complete' ] || fail "rename failure changed public metadata"

  write_complete_candidate
  out=$(PATH="$fake:$PATH" FM_HOME="$HOME_DIR" FM_TEST_MV_MODE=copy \
    FM_TEST_HELPER="$helper" FM_TEST_CANDIDATE="$candidate" FM_TEST_PUBLIC="$public" \
    bash -c '. "$0/bin/backends/herdr.sh"; eval "$FM_TEST_HELPER"; spawn_herdr_metadata_publish "$FM_TEST_CANDIDATE" "$FM_TEST_PUBLIC"' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "copy-and-lie rename reported publication success"
  [ -f "$candidate" ] || fail "copy-and-lie fixture did not retain its candidate"
  [ "$(head -1 "$public")" = 'window=shared:w1:p1' ] \
    || fail "copy-and-lie fixture did not demonstrate changed public bytes"

  rm -f "$public"
  write_complete_candidate
  out=$(PATH="$fake:$PATH" FM_HOME="$HOME_DIR" FM_TEST_MV_MODE=noop \
    FM_TEST_HELPER="$helper" FM_TEST_CANDIDATE="$candidate" FM_TEST_PUBLIC="$public" \
    bash -c '. "$0/bin/backends/herdr.sh"; eval "$FM_TEST_HELPER"; spawn_herdr_metadata_publish "$FM_TEST_CANDIDATE" "$FM_TEST_PUBLIC"' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "false-success rename without a final public file was accepted"
  [ ! -e "$public" ] || fail "false-success rename created an unexpected public path"

  write_complete_candidate
  out=$(PATH="$fake:$PATH" FM_HOME="$HOME_DIR" FM_TEST_MV_MODE=symlink \
    FM_TEST_MV_SYMLINK_TARGET="$symlink_target" FM_TEST_HELPER="$helper" \
    FM_TEST_CANDIDATE="$candidate" FM_TEST_PUBLIC="$public" \
    bash -c '. "$0/bin/backends/herdr.sh"; eval "$FM_TEST_HELPER"; spawn_herdr_metadata_publish "$FM_TEST_CANDIDATE" "$FM_TEST_PUBLIC"' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "non-regular final Herdr public path was accepted"
  [ -L "$public" ] || fail "final-public verification fixture did not create its symlink"
  rm -f "$public"

  source=$(<"$ROOT/bin/fm-spawn.sh")
  assert_contains "$source" "META_OUTPUT=\"\$STATE/\$ID.meta\"" \
    "spawn lost the byte-compatible direct non-Herdr publication destination"
  assert_contains "$source" "spawn_herdr_metadata_publish \"\$HERDR_META_TEMP\" \"\$STATE/\$ID.meta\"" \
    "spawn does not route only its Herdr candidate through the atomic publisher"
  pass "Herdr metadata: complete-schema atomic publication refuses unsafe and unverifiable public paths"
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
test_fleet_state_detail_malformed_fallback
test_crew_state_display
test_send_display_and_routing
test_peek_display_and_raw_pipe
test_atomic_metadata_publication_behavior
