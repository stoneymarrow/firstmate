#!/usr/bin/env bash
# Focused fake-Herdr proof for guarded native primary label convergence.
# No real Herdr session is read or mutated.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-primary-labels.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3" ;; esac; }

make_fakebin() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=${@: -1}
case "$*" in
  *'comm='*) if [ "$pid" = 4242 ]; then printf 'pi\n'; else printf 'bash\n'; fi ;;
  *'args='*) if [ "$pid" = 4242 ]; then printf 'pi\n'; else printf 'bash test\n'; fi ;;
  *'ppid='*) if [ "$pid" = 4242 ]; then printf '1\n'; else printf '4242\n'; fi ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/bin/lsof" <<'SH'
#!/usr/bin/env bash
set -u
printf 'p4242\nn%s\n' "$FM_HERDR_TEST_PROCESS_CWD"
SH
  cat > "$dir/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=$FM_HERDR_TEST_STATE
log=$FM_HERDR_TEST_LOG
printf '%s' "${1:-}" >> "$log"
for arg in "${@:2}"; do printf '\037%s' "$arg" >> "$log"; done
printf '\n' >> "$log"
command=${1:-}; sub=${2:-}
case "$command:$sub" in
  session:list)
    jq '{sessions:.sessions}' "$state"
    ;;
  workspace:list)
    jq '{result:{workspaces:.workspaces}}' "$state"
    ;;
  tab:list)
    workspace=
    prev=
    for arg in "$@"; do
      if [ "$prev" = --workspace ]; then workspace=$arg; break; fi
      prev=$arg
    done
    if [ -n "$workspace" ]; then
      jq --arg workspace "$workspace" '{result:{tabs:[.tabs[] | select(.workspace_id == $workspace)]}}' "$state"
    else
      jq '{result:{tabs:.tabs}}' "$state"
    fi
    ;;
  pane:list)
    workspace=
    prev=
    for arg in "$@"; do
      if [ "$prev" = --workspace ]; then workspace=$arg; break; fi
      prev=$arg
    done
    jq --arg workspace "$workspace" '{result:{panes:[.panes[] | select(.workspace_id == $workspace)]}}' "$state"
    ;;
  pane:get)
    pane=${3:-}
    jq -e --arg pane "$pane" '
      [.panes[] | select(.pane_id == $pane)]
      | select(length == 1)
      | {result:{pane:.[0]}}
    ' "$state"
    ;;
  pane:process-info)
    pane=
    prev=
    for arg in "$@"; do
      if [ "$prev" = --pane ]; then pane=$arg; break; fi
      prev=$arg
    done
    jq --arg pane "$pane" '{result:{type:"pane_process_info",process_info:{pane_id:$pane,foreground_processes:.foreground_processes}}}' "$state"
    ;;
  workspace:rename)
    id=${3:-}; label=${4:-}; tmp=$(mktemp "${state}.XXXXXX")
    jq --arg id "$id" --arg label "$label" '.workspaces |= map(if .workspace_id == $id then .label=$label else . end)' "$state" > "$tmp" \
      && mv "$tmp" "$state"
    jq -e --arg id "$id" --arg label "$label" '
      [.workspaces[] | select(.workspace_id == $id)]
      | select(length == 1)
      | {result:{workspace:{workspace_id:.[0].workspace_id,label:.[0].label}}}
    ' "$state"
    ;;
  tab:rename)
    id=${3:-}; label=${4:-}; tmp=$(mktemp "${state}.XXXXXX")
    jq --arg id "$id" --arg label "$label" '.tabs |= map(if .tab_id == $id then .label=$label else . end)' "$state" > "$tmp" \
      && mv "$tmp" "$state"
    jq -e --arg id "$id" --arg label "$label" '
      [.tabs[] | select(.tab_id == $id)]
      | select(length == 1)
      | {result:{tab:{workspace_id:.[0].workspace_id,tab_id:.[0].tab_id,label:.[0].label}}}
    ' "$state"
    ;;
  pane:rename)
    if [ "$(jq -r '.fail_pane_rename_once // false' "$state")" = true ]; then
      tmp=$(mktemp "${state}.XXXXXX")
      jq '.fail_pane_rename_once=false' "$state" > "$tmp" && mv "$tmp" "$state"
      exit 1
    fi
    id=${3:-}; label=${4:-}; tmp=$(mktemp "${state}.XXXXXX")
    jq --arg id "$id" --arg label "$label" '.panes |= map(if .pane_id == $id then .label=$label else . end)' "$state" > "$tmp" \
      && mv "$tmp" "$state"
    jq -e --arg id "$id" --arg label "$label" '
      [.panes[] | select(.pane_id == $id)]
      | select(length == 1)
      | {result:{pane:{workspace_id:.[0].workspace_id,tab_id:.[0].tab_id,pane_id:.[0].pane_id,label:.[0].label}}}
    ' "$state"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/bin/ps" "$dir/bin/lsof" "$dir/bin/herdr"
  printf '%s' "$dir/bin"
}

setup_fixture() {  # <dir>
  local dir=$1
  FIXTURE_HOME="$dir/home"
  FIXTURE_STATE="$dir/herdr.json"
  FIXTURE_LOG="$dir/herdr.log"
  FIXTURE_SOCKET="$dir/session/herdr.sock"
  mkdir -p "$FIXTURE_HOME/state" "$(dirname "$FIXTURE_SOCKET")"
  : > "$FIXTURE_SOCKET"
  : > "$FIXTURE_LOG"
  printf '4242\n' > "$FIXTURE_HOME/state/.lock"
  jq -n --arg socket "$FIXTURE_SOCKET" --arg root "$ROOT" '{
    sessions:[{name:"shared",running:true,socket_path:$socket}],
    workspaces:[{workspace_id:"w1",label:"firstmate"}],
    tabs:[{workspace_id:"w1",tab_id:"w1:t1",label:"1"}],
    panes:[{workspace_id:"w1",tab_id:"w1:t1",pane_id:"w1:p1",label:"",foreground_cwd:$root}],
    foreground_processes:[{pid:4242,name:"pi"}],
    fail_pane_rename_once:false
  }' > "$FIXTURE_STATE"
}

run_labels() {  # <fakebin> [process-cwd]
  local fakebin=$1 process_cwd=${2:-$ROOT}
  PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$FIXTURE_HOME" FM_STATE_OVERRIDE="$FIXTURE_HOME/state" \
    FM_HERDR_TEST_STATE="$FIXTURE_STATE" FM_HERDR_TEST_LOG="$FIXTURE_LOG" \
    FM_HERDR_TEST_PROCESS_CWD="$process_cwd" \
    HERDR_ENV=1 HERDR_SOCKET_PATH="$FIXTURE_SOCKET" \
    HERDR_WORKSPACE_ID=w1 HERDR_TAB_ID=w1:t1 HERDR_PANE_ID=w1:p1 \
    "$ROOT/bin/fm-herdr-primary-labels.sh"
}

# Missing native tuple input is a strict silent no-op.
test_inert_without_exact_environment() {
  local dir fake out
  dir="$TMP_ROOT/inert"; setup_fixture "$dir"; fake=$(make_fakebin "$dir")
  out=$(env -u HERDR_SOCKET_PATH -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
    PATH="$fake:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$FIXTURE_HOME" \
    FM_STATE_OVERRIDE="$FIXTURE_HOME/state" FM_HERDR_TEST_STATE="$FIXTURE_STATE" \
    FM_HERDR_TEST_LOG="$FIXTURE_LOG" HERDR_ENV=1 "$ROOT/bin/fm-herdr-primary-labels.sh" 2>&1) \
    || fail "inert primary-label path failed"
  [ -z "$out" ] || fail "inert primary-label path printed '$out'"
  [ ! -s "$FIXTURE_LOG" ] || fail "inert primary-label path called Herdr"
  pass "Herdr primary labels: missing exact native tuple stays inert and silent"
}

# Full process ownership permits only exact-ID renames and converges silently.
test_owned_success() {
  local dir fake out calls
  dir="$TMP_ROOT/success"; setup_fixture "$dir"; fake=$(make_fakebin "$dir")
  out=$(run_labels "$fake" 2>&1) || fail "owned primary-label convergence failed: $out"
  [ -z "$out" ] || fail "successful primary-label convergence was not silent: $out"
  [ "$(jq -r '.workspaces[0].label' "$FIXTURE_STATE")" = 'firstmate · primary' ] \
    && [ "$(jq -r '.tabs[0].label' "$FIXTURE_STATE")" = 'firstmate · primary' ] \
    && [ "$(jq -r '.panes[0].label' "$FIXTURE_STATE")" = 'firstmate · primary' ] \
    || fail "owned primary tuple did not converge"
  calls=$(<"$FIXTURE_LOG")
  case "$calls" in *$'workspace\037rename\037w1\037firstmate · primary'*) : ;; *) fail "workspace rename did not use exact id" ;; esac
  case "$calls" in *$'tab\037rename\037w1:t1\037firstmate · primary'*) : ;; *) fail "tab rename did not use exact id" ;; esac
  case "$calls" in *$'pane\037rename\037w1:p1\037firstmate · primary'*) : ;; *) fail "pane rename did not use exact id" ;; esac
  case "$calls" in *$'close'*) fail "primary label path issued a close" ;; esac
  pass "Herdr primary labels: exact lock/process/cwd ownership converges by exact ids"
}

# Lock, process, cwd, socket, label, and collision failures refuse before rename.
test_ownership_refusals() {
  local mode dir fake out status tmp calls session_lock
  for mode in symlink-lock wrong-owner missing-process wrong-cwd duplicate-socket foreign-label target-collision session-busy; do
    dir="$TMP_ROOT/refuse-$mode"; setup_fixture "$dir"; fake=$(make_fakebin "$dir")
    case "$mode" in
      symlink-lock) rm -f "$FIXTURE_HOME/state/.lock"; printf '4242\n' > "$dir/lock"; ln -s "$dir/lock" "$FIXTURE_HOME/state/.lock" ;;
      wrong-owner) printf '4343\n' > "$FIXTURE_HOME/state/.lock" ;;
      missing-process) tmp=$(mktemp "${FIXTURE_STATE}.XXXXXX"); jq '.foreground_processes=[{pid:9999,name:"other"}]' "$FIXTURE_STATE" > "$tmp"; mv "$tmp" "$FIXTURE_STATE" ;;
      wrong-cwd) ;;
      duplicate-socket) tmp=$(mktemp "${FIXTURE_STATE}.XXXXXX"); jq '.sessions += [{name:"copy",running:true,socket_path:.sessions[0].socket_path}]' "$FIXTURE_STATE" > "$tmp"; mv "$tmp" "$FIXTURE_STATE" ;;
      foreign-label) tmp=$(mktemp "${FIXTURE_STATE}.XXXXXX"); jq '.tabs[0].label="foreign"' "$FIXTURE_STATE" > "$tmp"; mv "$tmp" "$FIXTURE_STATE" ;;
      target-collision) tmp=$(mktemp "${FIXTURE_STATE}.XXXXXX"); jq '.workspaces += [{workspace_id:"w2",label:"firstmate · primary"}]' "$FIXTURE_STATE" > "$tmp"; mv "$tmp" "$FIXTURE_STATE" ;;
      session-busy)
        session_lock=$(PATH="$fake:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$FIXTURE_HOME" \
          FM_HERDR_TEST_STATE="$FIXTURE_STATE" FM_HERDR_TEST_LOG="$FIXTURE_LOG" \
          bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path shared' "$ROOT") \
          || fail "could not derive fixture session lock"
        mkdir -p "$session_lock"
        printf '%s\n' "$$" > "$session_lock/pid"
        ;;
    esac
    if [ "$mode" = wrong-cwd ]; then
      out=$(run_labels "$fake" "$dir/not-firstmate" 2>&1); status=$?
    else
      out=$(run_labels "$fake" 2>&1); status=$?
    fi
    [ "$status" -ne 0 ] || fail "$mode ownership refusal succeeded"
    assert_contains "$out" 'HERDR_LABELS: refused:' "$mode refusal lacked HERDR_LABELS diagnostic"
    calls=$(<"$FIXTURE_LOG")
    case "$calls" in *$'\037rename\037'*) fail "$mode refusal renamed a Herdr object" ;; esac
    if [ "$mode" = session-busy ]; then
      rm -rf "$session_lock"
    fi
  done
  pass "Herdr primary labels: unsafe lock/process/cwd/socket/label/collision inputs refuse before rename"
}

# Session mutation locks use one globally unique physical socket identity.
# Running raw/symlink aliases refuse, stopped aliases do not participate, and
# distinct sockets produce distinct lock paths.
test_physical_socket_lock_identity() {
  local dir fake alias other tmp lock_a lock_b
  dir="$TMP_ROOT/physical-socket-lock"; setup_fixture "$dir"; fake=$(make_fakebin "$dir")
  alias="$dir/session/socket-alias"; ln -s "$FIXTURE_SOCKET" "$alias"
  tmp=$(mktemp "${FIXTURE_STATE}.XXXXXX")
  jq --arg alias "$alias" '.sessions += [{name:"alias",running:true,socket_path:$alias}]' \
    "$FIXTURE_STATE" > "$tmp"; mv "$tmp" "$FIXTURE_STATE"
  if PATH="$fake:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$FIXTURE_HOME" \
    FM_HERDR_TEST_STATE="$FIXTURE_STATE" FM_HERDR_TEST_LOG="$FIXTURE_LOG" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path shared' \
      "$ROOT" >/dev/null 2>&1; then
    fail "running symlink-equivalent socket aliases received separate lock authority"
  fi

  tmp=$(mktemp "${FIXTURE_STATE}.XXXXXX")
  jq '.sessions[1].running=false' "$FIXTURE_STATE" > "$tmp"; mv "$tmp" "$FIXTURE_STATE"
  lock_a=$(PATH="$fake:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$FIXTURE_HOME" \
    FM_HERDR_TEST_STATE="$FIXTURE_STATE" FM_HERDR_TEST_LOG="$FIXTURE_LOG" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path shared' "$ROOT") \
    || fail "stopped socket alias blocked the running session lock"

  other="$dir/session/other.sock"; : > "$other"
  tmp=$(mktemp "${FIXTURE_STATE}.XXXXXX")
  jq --arg other "$other" '.sessions += [{name:"other",running:true,socket_path:$other}]' \
    "$FIXTURE_STATE" > "$tmp"; mv "$tmp" "$FIXTURE_STATE"
  lock_b=$(PATH="$fake:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$FIXTURE_HOME" \
    FM_HERDR_TEST_STATE="$FIXTURE_STATE" FM_HERDR_TEST_LOG="$FIXTURE_LOG" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path other' "$ROOT") \
    || fail "distinct physical socket did not receive a lock path"
  [ "$lock_a" != "$lock_b" ] || fail "distinct physical sockets shared one lock path"
  pass "Herdr session lock: globally unique physical sockets own lock identity"
}

# A failed third rename leaves an old/new mix with a clear diagnostic; the next
# locked startup accepts only that mix and completes it.
test_partial_convergence() {
  local dir fake tmp out status
  dir="$TMP_ROOT/partial"; setup_fixture "$dir"; fake=$(make_fakebin "$dir")
  tmp=$(mktemp "${FIXTURE_STATE}.XXXXXX")
  jq '.fail_pane_rename_once=true' "$FIXTURE_STATE" > "$tmp"; mv "$tmp" "$FIXTURE_STATE"
  out=$(run_labels "$fake" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "injected pane rename failure reported success"
  assert_contains "$out" 'HERDR_LABELS: partial exact-ID rename:' "partial rename lacked convergence diagnostic"
  [ "$(jq -r '.workspaces[0].label' "$FIXTURE_STATE")" = 'firstmate · primary' ] \
    && [ "$(jq -r '.tabs[0].label' "$FIXTURE_STATE")" = 'firstmate · primary' ] \
    && [ "$(jq -r '.panes[0].label' "$FIXTURE_STATE")" = '' ] \
    || fail "partial rename did not retain the expected old/new mix"
  out=$(run_labels "$fake" 2>&1) || fail "second locked convergence failed: $out"
  [ -z "$out" ] || fail "successful retry was not silent: $out"
  [ "$(jq -r '.panes[0].label' "$FIXTURE_STATE")" = 'firstmate · primary' ] \
    || fail "second locked convergence did not finish the pane label"
  pass "Herdr primary labels: partial old/new mix converges on the next locked startup"
}

# Session start invokes the owner only after lock acquisition and before
# ordinary bootstrap; the read-only path never invokes it.
test_session_start_locked_wiring() {
  local root home trace out
  root="$TMP_ROOT/session-start-root"; home="$root/home"; trace="$root/trace"
  mkdir -p "$root/bin" "$home/state" "$home/data" "$home/config"
  cp "$ROOT/bin/fm-session-start.sh" "$root/bin/fm-session-start.sh"
  cat > "$root/bin/fm-backend.sh" <<'SH'
fm_meta_get() { return 0; }
fm_backend_of_meta() { printf 'herdr'; }
fm_backend_target_of_meta() { return 0; }
fm_backend_target_exists() { return 1; }
SH
  cat > "$root/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
fm_backlog_backend_manual() { return 1; }
SH
  cat > "$root/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_LOCK_RC:-0}" = 0 ]; then printf 'lock acquired\n'; exit 0; fi
printf 'lock refused\n' >&2
exit 1
SH
  cat > "$root/bin/fm-herdr-primary-labels.sh" <<'SH'
#!/usr/bin/env bash
printf 'primary\n' >> "$FM_TEST_PRIMARY_TRACE"
SH
  cat > "$root/bin/fm-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
printf 'bootstrap\n' >> "$FM_TEST_PRIMARY_TRACE"
SH
  for stub in fm-herdr-session-cleanup.sh fm-wake-drain.sh fm-supervision-instructions.sh fm-guard.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/$stub"
  done
  cat > "$root/bin/fm-harness.sh" <<'SH'
#!/usr/bin/env bash
printf 'unknown\n'
SH
  chmod +x "$root/bin/"*.sh
  : > "$trace"
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_TEST_PRIMARY_TRACE="$trace" \
    FM_TEST_LOCK_RC=0 "$root/bin/fm-session-start.sh") || fail "locked session-start fixture failed"
  [ "$(cat "$trace")" = $'primary\nbootstrap' ] \
    || fail "primary label owner did not run before bootstrap on locked startup: $(cat "$trace")"
  : > "$trace"
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_TEST_PRIMARY_TRACE="$trace" \
    FM_TEST_LOCK_RC=1 "$root/bin/fm-session-start.sh") || fail "read-only session-start fixture failed"
  case "$(cat "$trace")" in *primary*) fail "read-only session start invoked primary label owner" ;; esac
  pass "Herdr primary labels: session start calls owner only on locked path before bootstrap"
}

test_inert_without_exact_environment
test_session_start_locked_wiring
test_owned_success
test_ownership_refusals
test_physical_socket_lock_identity
test_partial_convergence
