#!/usr/bin/env bash
# Converge the already-running native Herdr primary workspace, tab, and pane
# onto one readable primary label after proving this process owns all three.
#
# This owner runs only from the locked path of fm-session-start.sh. It is inert
# outside a native Herdr pane, in a marked second-mate home, or when any exact
# Herdr socket/workspace/tab/pane environment identity is absent. It never
# creates or closes an object, never mutates by label, and never treats a label
# as routing authority.
#
# Usage: fm-herdr-primary-labels.sh
# Success, including an already-converged no-op, is silent. A refusal or partial
# exact-ID rename prints one HERDR_LABELS: line and returns non-zero.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/backends/herdr.sh
. "$SCRIPT_DIR/backends/herdr.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_HERDR_PRIMARY_SESSION=
FM_HERDR_PRIMARY_SESSION_LOCK=
FM_HERDR_PRIMARY_SESSION_LOCK_HELD=0
FM_HERDR_PRIMARY_WORKSPACE_LABEL=
FM_HERDR_PRIMARY_TAB_LABEL=
FM_HERDR_PRIMARY_PANE_LABEL=
FM_HERDR_PRIMARY_WORKSPACES=

fm_herdr_primary_refuse() {  # <reason>
  printf 'HERDR_LABELS: refused: %s\n' "$1" >&2
  return 1
}

fm_herdr_primary_partial() {  # <reason>
  printf 'HERDR_LABELS: partial exact-ID rename: %s; next locked startup may converge the old/new mix\n' "$1" >&2
  return 1
}

fm_herdr_primary_session_lock_release() {
  [ "$FM_HERDR_PRIMARY_SESSION_LOCK_HELD" -eq 1 ] || return 0
  FM_HERDR_PRIMARY_SESSION_LOCK_HELD=0
  fm_lock_release "$FM_HERDR_PRIMARY_SESSION_LOCK" || true
}

fm_herdr_primary_exact_identity() {  # <value>
  case "$1" in ''|*[[:space:][:cntrl:]]*) return 1 ;; esac
}

fm_herdr_primary_path_identity() {  # <absolute-path>
  local path=${1:-} dir base
  case "$path" in /*) ;; *) return 1 ;; esac
  dir=$(dirname "$path")
  base=$(basename "$path")
  [ -n "$base" ] && [ -d "$dir" ] || return 1
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "$dir" "$base"
}

fm_herdr_primary_resolve_session() {  # <socket-path>
  local wanted=$1 raw rows row name socket identity count=0 found=
  wanted=$(fm_herdr_primary_path_identity "$wanted") || return 1
  raw=$(herdr session list --json 2>/dev/null) || return 1
  rows=$(printf '%s' "$raw" | jq -er '
    select((.sessions | type) == "array")
    | .sessions[]?
    | select(.running == true)
    | select((.name | type) == "string" and (.name | length) > 0)
    | select((.socket_path | type) == "string" and (.socket_path | length) > 0)
    | [.name,.socket_path] | @tsv
  ' 2>/dev/null) || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name=${row%%$'\t'*}
    socket=${row#*$'\t'}
    [ -n "$name" ] && [ -n "$socket" ] && [ "$socket" != "$row" ] || return 1
    fm_herdr_primary_exact_identity "$name" || return 1
    identity=$(fm_herdr_primary_path_identity "$socket") || return 1
    [ "$identity" = "$wanted" ] || continue
    count=$((count + 1))
    found=$name
  done <<EOF
$rows
EOF
  [ "$count" -eq 1 ] || return 1
  FM_HERDR_PRIMARY_SESSION=$found
}

fm_herdr_primary_tuple_snapshot() {  # <session> <workspace> <tab> <pane>
  local session=$1 workspace=$2 tab=$3 pane=$4 tabs panes pane_get
  local workspace_count tab_count pane_count
  FM_HERDR_PRIMARY_WORKSPACES=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$FM_HERDR_PRIMARY_WORKSPACES" | jq -e '
    (.result.workspaces | type) == "array"
    and all(.result.workspaces[]?;
      (.workspace_id | type) == "string" and (.workspace_id | length) > 0
      and (.label | type) == "string")
    and ([.result.workspaces[].workspace_id] | length)
        == ([.result.workspaces[].workspace_id] | unique | length)
  ' >/dev/null 2>&1 || return 1
  workspace_count=$(printf '%s' "$FM_HERDR_PRIMARY_WORKSPACES" | jq -r --arg workspace "$workspace" \
    '[.result.workspaces[]? | select(.workspace_id == $workspace)] | length' 2>/dev/null) || return 1
  [ "$workspace_count" -eq 1 ] || return 1
  FM_HERDR_PRIMARY_WORKSPACE_LABEL=$(printf '%s' "$FM_HERDR_PRIMARY_WORKSPACES" | jq -er --arg workspace "$workspace" \
    '.result.workspaces[] | select(.workspace_id == $workspace) | .label' 2>/dev/null) || return 1

  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e '
    (.result.tabs | type) == "array"
    and all(.result.tabs[]?;
      (.workspace_id | type) == "string" and (.workspace_id | length) > 0
      and (.tab_id | type) == "string" and (.tab_id | length) > 0
      and (.label | type) == "string")
    and ([.result.tabs[] | [.workspace_id,.tab_id]] | length)
        == ([.result.tabs[] | [.workspace_id,.tab_id]] | unique | length)
  ' >/dev/null 2>&1 || return 1
  tab_count=$(printf '%s' "$tabs" | jq -r --arg workspace "$workspace" --arg tab "$tab" \
    '[.result.tabs[]? | select(.workspace_id == $workspace and .tab_id == $tab)] | length' 2>/dev/null) || return 1
  [ "$tab_count" -eq 1 ] || return 1
  FM_HERDR_PRIMARY_TAB_LABEL=$(printf '%s' "$tabs" | jq -er --arg workspace "$workspace" --arg tab "$tab" \
    '.result.tabs[] | select(.workspace_id == $workspace and .tab_id == $tab) | .label' 2>/dev/null) || return 1

  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e '
    (.result.panes | type) == "array"
    and all(.result.panes[]?;
      (.workspace_id | type) == "string" and (.workspace_id | length) > 0
      and (.tab_id | type) == "string" and (.tab_id | length) > 0
      and (.pane_id | type) == "string" and (.pane_id | length) > 0
      and ((.label // "") | type) == "string")
    and ([.result.panes[] | [.workspace_id,.tab_id,.pane_id]] | length)
        == ([.result.panes[] | [.workspace_id,.tab_id,.pane_id]] | unique | length)
  ' >/dev/null 2>&1 || return 1
  pane_count=$(printf '%s' "$panes" | jq -r \
    --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" \
    '[.result.panes[]? | select(.workspace_id == $workspace and .tab_id == $tab and .pane_id == $pane)] | length' \
    2>/dev/null) || return 1
  [ "$pane_count" -eq 1 ] || return 1
  FM_HERDR_PRIMARY_PANE_LABEL=$(printf '%s' "$panes" | jq -er \
    --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" \
    '.result.panes[] | select(.workspace_id == $workspace and .tab_id == $tab and .pane_id == $pane) | (.label // "")' \
    2>/dev/null) || return 1

  pane_get=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  printf '%s' "$pane_get" | jq -e \
    --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" \
    --arg label "$FM_HERDR_PRIMARY_PANE_LABEL" '
      .result.pane.workspace_id == $workspace
      and .result.pane.tab_id == $tab
      and .result.pane.pane_id == $pane
      and (.result.pane.label // "") == $label
    ' >/dev/null 2>&1
}

fm_herdr_primary_process_cwd() {  # <pid>
  local pid=$1 path rows
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -L "/proc/$pid/cwd" ]; then
    path=$(readlink "/proc/$pid/cwd" 2>/dev/null) || return 1
  else
    command -v lsof >/dev/null 2>&1 || return 1
    rows=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null) || return 1
    path=$(printf '%s\n' "$rows" | sed -n 's/^n//p')
    [ "$(printf '%s\n' "$path" | awk 'NF { n++ } END { print n+0 }')" -eq 1 ] || return 1
  fi
  [ -d "$path" ] || return 1
  (cd "$path" 2>/dev/null && pwd -P)
}

fm_herdr_primary_process_owned() {  # <session> <pane> <owner-pid> <root>
  local session=$1 pane=$2 owner=$3 root=$4 info matches process_cwd root_cwd
  info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -e --arg pane "$pane" '
    .result.type == "pane_process_info"
    and .result.process_info.pane_id == $pane
    and (.result.process_info.foreground_processes | type) == "array"
    and all(.result.process_info.foreground_processes[]?;
      (.pid | type) == "number" and .pid > 1 and (.pid | floor) == .pid)
  ' >/dev/null 2>&1 || return 1
  matches=$(printf '%s' "$info" | jq -r --argjson owner "$owner" \
    '[.result.process_info.foreground_processes[]? | select(.pid == $owner)] | length' 2>/dev/null) || return 1
  [ "$matches" -eq 1 ] || return 1
  process_cwd=$(fm_herdr_primary_process_cwd "$owner") || return 1
  root_cwd=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  [ "$process_cwd" = "$root_cwd" ]
}

fm_herdr_primary_collision_free() {  # <session> <workspace> <tab> <pane> <target>
  local session=$1 workspace=$2 tab=$3 pane=$4 target=$5 tabs count rows ws panes
  count=$(printf '%s' "$FM_HERDR_PRIMARY_WORKSPACES" | jq -r \
    --arg workspace "$workspace" --arg target "$target" \
    '[.result.workspaces[]? | select(.workspace_id != $workspace and .label == $target)] | length' \
    2>/dev/null) || return 1
  [ "$count" -eq 0 ] || return 1

  tabs=$(fm_backend_herdr_cli "$session" tab list 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e '
    (.result.tabs | type) == "array"
    and all(.result.tabs[]?;
      (.workspace_id | type) == "string" and (.workspace_id | length) > 0
      and (.tab_id | type) == "string" and (.tab_id | length) > 0
      and (.label | type) == "string")
    and ([.result.tabs[] | [.workspace_id,.tab_id]] | length)
        == ([.result.tabs[] | [.workspace_id,.tab_id]] | unique | length)
  ' >/dev/null 2>&1 || return 1
  count=$(printf '%s' "$tabs" | jq -r \
    --arg workspace "$workspace" --arg tab "$tab" --arg target "$target" \
    '[.result.tabs[]?
      | select((.workspace_id != $workspace or .tab_id != $tab) and .label == $target)]
    | length' 2>/dev/null) || return 1
  [ "$count" -eq 0 ] || return 1

  rows=$(printf '%s' "$FM_HERDR_PRIMARY_WORKSPACES" | jq -r '.result.workspaces[].workspace_id' 2>/dev/null) || return 1
  while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$ws" 2>/dev/null) || return 1
    printf '%s' "$panes" | jq -e '
      (.result.panes | type) == "array"
      and all(.result.panes[]?;
        (.workspace_id | type) == "string" and (.workspace_id | length) > 0
        and (.tab_id | type) == "string" and (.tab_id | length) > 0
        and (.pane_id | type) == "string" and (.pane_id | length) > 0
        and ((.label // "") | type) == "string")
      and ([.result.panes[] | [.workspace_id,.tab_id,.pane_id]] | length)
          == ([.result.panes[] | [.workspace_id,.tab_id,.pane_id]] | unique | length)
    ' >/dev/null 2>&1 || return 1
    count=$(printf '%s' "$panes" | jq -r \
      --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" --arg target "$target" \
      '[.result.panes[]?
        | select((.workspace_id != $workspace or .tab_id != $tab or .pane_id != $pane)
                 and (.label // "") == $target)]
      | length' 2>/dev/null) || return 1
    [ "$count" -eq 0 ] || return 1
  done <<EOF
$rows
EOF
}

fm_herdr_primary_labels_run() {
  local lock="$STATE/.lock" owner ancestry workspace tab pane socket session target
  [ -f "$lock" ] && [ ! -L "$lock" ] \
    || { fm_herdr_primary_refuse "home session lock is not a regular non-symlink file"; return 1; }
  owner=$(cat "$lock" 2>/dev/null) \
    || { fm_herdr_primary_refuse "home session lock is unreadable"; return 1; }
  case "$owner" in ''|*[!0-9]*) fm_herdr_primary_refuse "home session lock has no exact harness pid"; return 1 ;; esac
  ancestry=$(fm_harness_ancestry_pid) \
    || { fm_herdr_primary_refuse "this session has no verified harness ancestry pid"; return 1; }
  [ "$owner" = "$ancestry" ] \
    || { fm_herdr_primary_refuse "home session lock belongs to a different harness process"; return 1; }

  workspace=$HERDR_WORKSPACE_ID
  tab=$HERDR_TAB_ID
  pane=$HERDR_PANE_ID
  socket=$HERDR_SOCKET_PATH
  if ! fm_herdr_primary_exact_identity "$workspace" \
    || ! fm_herdr_primary_exact_identity "$tab" \
    || ! fm_herdr_primary_exact_identity "$pane"; then
    fm_herdr_primary_refuse "native Herdr tuple contains an invalid identity"
    return 1
  fi
  case "$socket" in /*) ;; *) fm_herdr_primary_refuse "HERDR_SOCKET_PATH is not absolute"; return 1 ;; esac
  fm_herdr_primary_resolve_session "$socket" \
    || { fm_herdr_primary_refuse "HERDR_SOCKET_PATH does not identify exactly one running named session"; return 1; }
  session=$FM_HERDR_PRIMARY_SESSION
  FM_HERDR_PRIMARY_SESSION_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$session") \
    || { fm_herdr_primary_refuse "running named session has no unambiguous machine-private lock"; return 1; }
  if ! fm_lock_try_acquire "$FM_HERDR_PRIMARY_SESSION_LOCK"; then
    fm_herdr_primary_refuse "running named Herdr session is busy"
    return 1
  fi
  FM_HERDR_PRIMARY_SESSION_LOCK_HELD=1
  target=$(fm_backend_herdr_format_label firstmate primary) \
    || { fm_herdr_primary_refuse "adapter primary-label formatter failed"; return 1; }

  fm_herdr_primary_tuple_snapshot "$session" "$workspace" "$tab" "$pane" \
    || { fm_herdr_primary_refuse "environment-provided workspace/tab/pane tuple is absent or unreadable"; return 1; }
  fm_herdr_primary_process_owned "$session" "$pane" "$owner" "$FM_ROOT" \
    || { fm_herdr_primary_refuse "exact pane process does not prove lock-owner pid and Firstmate-root cwd"; return 1; }
  case "$FM_HERDR_PRIMARY_WORKSPACE_LABEL" in firstmate|""|"$target") ;; *) fm_herdr_primary_refuse "primary workspace has a foreign label"; return 1 ;; esac
  case "$FM_HERDR_PRIMARY_TAB_LABEL" in 1|""|"$target") ;; *) fm_herdr_primary_refuse "primary tab has a foreign label"; return 1 ;; esac
  case "$FM_HERDR_PRIMARY_PANE_LABEL" in ""|"$target") ;; *) fm_herdr_primary_refuse "primary pane has a foreign label"; return 1 ;; esac
  fm_herdr_primary_collision_free "$session" "$workspace" "$tab" "$pane" "$target" \
    || { fm_herdr_primary_refuse "a competing primary semantic label exists or label inventory is unreadable"; return 1; }

  if [ "$FM_HERDR_PRIMARY_WORKSPACE_LABEL" != "$target" ]; then
    fm_backend_herdr_workspace_rename_exact "$session" "$workspace" "$target" \
      || { fm_herdr_primary_partial "workspace $workspace rename response was not verified"; return 1; }
  fi
  if [ "$FM_HERDR_PRIMARY_TAB_LABEL" != "$target" ]; then
    fm_backend_herdr_tab_rename_exact "$session" "$workspace" "$tab" "$target" \
      || { fm_herdr_primary_partial "tab $tab rename response was not verified"; return 1; }
  fi
  if [ "$FM_HERDR_PRIMARY_PANE_LABEL" != "$target" ]; then
    fm_backend_herdr_pane_rename_exact "$session" "$workspace" "$tab" "$pane" "$target" \
      || { fm_herdr_primary_partial "pane $pane rename response was not verified"; return 1; }
  fi

  fm_herdr_primary_tuple_snapshot "$session" "$workspace" "$tab" "$pane" \
    || { fm_herdr_primary_partial "final exact tuple could not be verified"; return 1; }
  [ "$FM_HERDR_PRIMARY_WORKSPACE_LABEL" = "$target" ] \
    && [ "$FM_HERDR_PRIMARY_TAB_LABEL" = "$target" ] \
    && [ "$FM_HERDR_PRIMARY_PANE_LABEL" = "$target" ] \
    || { fm_herdr_primary_partial "final tuple retained a non-target label"; return 1; }
  fm_herdr_primary_collision_free "$session" "$workspace" "$tab" "$pane" "$target" \
    || { fm_herdr_primary_partial "final target label became ambiguous"; return 1; }
  return 0
}

fm_herdr_primary_labels_main() {
  [ "${HERDR_ENV:-}" = 1 ] || return 0
  [ ! -e "$FM_HOME/$FM_BACKEND_HERDR_SECONDMATE_MARKER" ] \
    && [ ! -L "$FM_HOME/$FM_BACKEND_HERDR_SECONDMATE_MARKER" ] || return 0
  [ -n "${HERDR_SOCKET_PATH:-}" ] \
    && [ -n "${HERDR_WORKSPACE_ID:-}" ] \
    && [ -n "${HERDR_TAB_ID:-}" ] \
    && [ -n "${HERDR_PANE_ID:-}" ] || return 0
  if ! command -v herdr >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    fm_herdr_primary_refuse "herdr or jq is unavailable"
    return 1
  fi
  fm_herdr_primary_labels_run
}

if [ "${FM_HERDR_PRIMARY_LABELS_SOURCE_ONLY:-0}" != 1 ]; then
  trap fm_herdr_primary_session_lock_release EXIT
  fm_herdr_primary_labels_main
fi
