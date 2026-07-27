#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")
N=${2:-40}

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

# Pipes retain capture bytes exactly. Only an interactive Herdr read with
# recorded metadata gets a label-first display header; the recorded target
# remains visible for routing audit and is never derived from that label.
if [ "$BACKEND" = herdr ] && [ -t 1 ]; then
  META=$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)
  [ -n "$META" ] || META=$(fm_backend_meta_for_window "$T" "$STATE" 2>/dev/null || true)
  if [ -n "$META" ]; then
    DISPLAY_LABEL=$(fm_meta_get "$META" display_label)
    SESSION_DISPLAY_LABEL=$(fm_meta_get "$META" herdr_session_display_label)
    printf 'label: %s · session: %s · target: %s\n' \
      "${DISPLAY_LABEL:--}" "${SESSION_DISPLAY_LABEL:--}" "$T"
  fi
fi

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
