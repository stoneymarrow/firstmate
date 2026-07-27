#!/usr/bin/env bash
# Promote one scout task to a ship task in place: the worker keeps its exact
# endpoint, isolated copy, and loaded context while teardown protection returns.
# Every promotion holds state/.spawn-<id>.lock before reading metadata and uses
# same-directory temporary publication. Herdr promotions then hold the exact
# named-session lock second and delegate the recoverable tab/pane, presentation
# journal, and metadata transaction to the Herdr adapter.
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -ne 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid promotion request" >&2
  exit 2
fi
ID=$1
META="$STATE/$ID.meta"
TASK_LOCK="$STATE/.spawn-$ID.lock"
TASK_LOCK_HELD=0
HERDR_SESSION_LOCK=""
HERDR_SESSION_LOCK_HELD=0

promote_cleanup() {
  local status=$?
  if [ "$HERDR_SESSION_LOCK_HELD" = 1 ]; then
    HERDR_SESSION_LOCK_HELD=0
    fm_lock_release "$HERDR_SESSION_LOCK" || true
  fi
  if [ "$TASK_LOCK_HELD" = 1 ]; then
    TASK_LOCK_HELD=0
    fm_lock_release "$TASK_LOCK" || true
  fi
  return "$status"
}
trap promote_cleanup EXIT

if ! fm_lock_try_acquire "$TASK_LOCK"; then
  echo "error: task $ID is busy; promotion did not read or change its metadata" >&2
  exit 1
fi
TASK_LOCK_HELD=1
"$FM_ROOT/bin/fm-guard.sh" || true

[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: no safe regular meta for task $ID at $META" >&2
  exit 1
}
if grep -qx 'backend=herdr' "$META"; then
  # Any Herdr claim enters the strict adapter validator, including a malformed
  # record with another competing backend field.
  BACKEND=herdr
else
  BACKEND=$(fm_backend_of_meta "$META")
fi

promote_generic_metadata() {
  local meta=$1 id=$2 state tmp line
  grep -qx 'kind=scout' "$meta" || {
    echo "error: task $id is not a scout task (kind=scout not in meta)" >&2
    return 1
  }
  state=$(dirname "$meta")
  tmp=$(mktemp "$state/.${id}.meta.promote.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*) ;;
      *) printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; } ;;
    esac
  done < "$meta"
  printf 'kind=ship\n' >> "$tmp" || { rm -f "$tmp"; return 1; }
  grep -qx 'kind=ship' "$tmp" || { rm -f "$tmp"; return 1; }
  [ -f "$meta" ] && [ ! -L "$meta" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta"
}

if [ "$BACKEND" = herdr ]; then
  fm_backend_source herdr || exit 1
  HERDR_SESSION=$(fm_backend_herdr_meta_field_exact "$META" herdr_session) || {
    echo "error: malformed herdr session identity in $META" >&2
    exit 1
  }
  HERDR_SESSION_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$HERDR_SESSION") || {
    echo "error: exact named herdr session lock is unavailable for promotion" >&2
    exit 1
  }
  if ! fm_lock_try_acquire "$HERDR_SESSION_LOCK"; then
    echo "error: named herdr session is busy; promotion changed nothing" >&2
    exit 1
  fi
  HERDR_SESSION_LOCK_HELD=1
  fm_backend_herdr_promote_scout_to_ship "$STATE" "$META" "$ID"
else
  promote_generic_metadata "$META" "$ID"
fi

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
