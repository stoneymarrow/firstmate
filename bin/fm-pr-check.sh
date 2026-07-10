#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
META_LOCK="$STATE/.$ID.meta.lock"
LOOKUP_META_EXISTS=0
LOOKUP_WT=
LOOKUP_WINDOW=
LOOKUP_TERMINAL=
PR_HEAD=
pr_check_cleanup() {
  local status=$?
  set +e
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK"
  return "$status"
}
trap pr_check_cleanup EXIT

[ -d "$STATE" ] || { echo "error: state dir $STATE is missing" >&2; exit 1; }
if [ -f "$META" ]; then
  LOOKUP_META_EXISTS=1
  LOOKUP_WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  LOOKUP_WINDOW=$(grep '^window=' "$META" | tail -1 | cut -d= -f2- || true)
  LOOKUP_TERMINAL=$(grep '^terminal=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -n "$LOOKUP_WT" ] && [ -d "$LOOKUP_WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$LOOKUP_WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
fi

fm_lock_acquire_wait "$META_LOCK"
GENERATION_MATCHED=0
if [ "$LOOKUP_META_EXISTS" = 1 ] && [ -f "$META" ]; then
  LOCKED_WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  LOCKED_WINDOW=$(grep '^window=' "$META" | tail -1 | cut -d= -f2- || true)
  LOCKED_TERMINAL=$(grep '^terminal=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ "$LOCKED_WT" = "$LOOKUP_WT" ] && [ "$LOCKED_WINDOW" = "$LOOKUP_WINDOW" ] && [ "$LOCKED_TERMINAL" = "$LOOKUP_TERMINAL" ]; then
    GENERATION_MATCHED=1
    if ! grep -qxF "pr=$URL" "$META"; then
      echo "pr=$URL" >> "$META"
    fi
    if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
      echo "pr_head=$PR_HEAD" >> "$META"
    fi
  fi
fi

if [ "$GENERATION_MATCHED" = 1 ]; then
  cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
  fm_lock_release "$META_LOCK"
  META_LOCK=
  echo "armed: state/$ID.check.sh polls $URL"
  exit 0
fi
fm_lock_release "$META_LOCK"
META_LOCK=
echo "not armed: task $ID metadata changed during PR lookup; preserved the current generation and any existing poll" >&2
