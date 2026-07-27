#!/usr/bin/env bash
# Promote one scout task to a ship task in place: the worker keeps its exact
# endpoint, isolated copy, and loaded context while teardown protection returns.
#
# Non-Herdr metadata uses the historical kind-only block byte for byte: no task
# lock, stricter id check, regular-file check, or private temporary publication
# is added in this Herdr-only lane. An exact backend=herdr claim enters the
# strict path, even if a competing backend field makes the record malformed.
# The strict path takes state/.spawn-<id>.lock before validating metadata, then
# the globally unique physical-socket lock, and delegates the recoverable live
# label, presentation journal, and metadata transaction to the Herdr adapter.
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

# Preserve the literal pre-Herdr promotion behavior for every record without an
# exact backend=herdr line. Do not harden this branch under Herdr-only authority.
if ! grep -qx 'backend=herdr' "$META"; then
  grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

  TMP="$META.tmp"
  grep -v '^kind=' "$META" > "$TMP"
  echo "kind=ship" >> "$TMP"
  mv "$TMP" "$META"

  HOME_Q=$(printf '%q' "$FM_HOME")
  echo "promoted $ID to ship (teardown protection restored)"
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
  exit 0
fi

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_task_id_path_safe "$ID" || {
  echo "error: invalid Herdr promotion request" >&2
  exit 2
}
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

[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: no safe regular Herdr meta for task $ID at $META" >&2
  exit 1
}
fm_backend_source herdr || exit 1
fm_backend_herdr_metadata_validate_record "$META" || exit 1
[ "$(grep -c '^backend=herdr$' "$META" 2>/dev/null || true)" = 1 ] \
  && [ "$(grep -c '^backend=' "$META" 2>/dev/null || true)" = 1 ] || {
  echo "error: malformed Herdr backend claim in $META" >&2
  exit 1
}
HERDR_SESSION=$(fm_backend_herdr_meta_field_exact "$META" herdr_session) || {
  echo "error: malformed herdr session identity in $META" >&2
  exit 1
}
HERDR_SESSION_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$HERDR_SESSION") || {
  echo "error: exact physical-socket Herdr session lock is unavailable for promotion" >&2
  exit 1
}
if ! fm_lock_try_acquire "$HERDR_SESSION_LOCK"; then
  echo "error: named herdr session is busy; promotion changed nothing" >&2
  exit 1
fi
HERDR_SESSION_LOCK_HELD=1
fm_backend_herdr_metadata_validate_record "$META" || exit 1
[ "$(grep -c '^backend=herdr$' "$META" 2>/dev/null || true)" = 1 ] \
  && [ "$(grep -c '^backend=' "$META" 2>/dev/null || true)" = 1 ] || exit 1
fm_backend_herdr_promote_scout_to_ship "$STATE" "$META" "$ID"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
