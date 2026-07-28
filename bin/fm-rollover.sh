#!/usr/bin/env bash
# fm-rollover.sh - firstmate's handler for the context-rollover decision key.
#
# The external context sensor stops a crewmate window at its hard ceiling and the
# handoff actuator offers the envelope; both append one supervisor-actionable
# `blocked [key=context-rollover]: ...` line to state/<id>.status. Nothing inside
# a stopped window can start its own successor, so that event is firstmate's to
# clear. This script is that clearing action: it retires the stopped session and
# relaunches the same task, same identity, on the SAME preserved worktree.
#
# Usage:
#   fm-rollover.sh status <task-id>
#   fm-rollover.sh run <task-id> [--harness <name>] [--model <name>] [--effort <level>]
#   fm-rollover.sh audit [--max-age-seconds <n>] [<task-id>...]
#   fm-rollover.sh -h|--help
#
#   status  print one line per task fact: whether a context-rollover decision is
#           open, the recorded endpoint and preserved worktree, and the state of
#           any prior rollover attempt. Exit 0 when a rollover is open and
#           runnable, 3 when nothing is open, 1 on an unusable record.
#   run     perform the rollover. Refuses unless a context-rollover decision is
#           genuinely open in the task's status stream, refuses a kind=secondmate
#           task, and refuses unless the recorded worktree is still a real git
#           worktree root distinct from the project's primary checkout. It never
#           removes a worktree, a branch, or a commit: teardown owns disposal and
#           a rollover preserves everything the predecessor left behind.
#           --harness/--model/--effort override the recorded profile for the
#           successor; without them the predecessor's recorded profile is reused.
#   audit   report rollovers that started and never completed. A task with an open
#           context-rollover decision older than --max-age-seconds (default 900)
#           and no successful successor is a stalled rollover: the task belongs to
#           no live window while nothing looks wrong. Prints one
#           `ROLLOVER_STALLED: <id> ...` line per stalled task and exits 1; prints
#           nothing and exits 0 when every rollover is accounted for.
#
# Durable record: state/<id>.rollover, written before the first mutation and
# updated at each step, so a crash mid-rollover leaves the predecessor endpoint,
# the preserved worktree, and the reached step recoverable. Fields:
#   state=            starting|retired|succeeded|retire-failed|spawn-failed
#   started_at=       epoch seconds
#   predecessor=      the retired backend endpoint
#   predecessor_backend=
#   worktree=         the preserved copy carried across
#   successor=        the new endpoint, once launched
# The record is task-scoped and removed by teardown along with the task's other
# state files.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# The one decision key the sensor's hard handoff opens and the handoff close
# resolves. Stated here once; every other mention is a cross-reference.
ROLLOVER_KEY=context-rollover
AUDIT_DEFAULT_MAX_AGE=900

die() { echo "error: $*" >&2; exit 1; }

meta_value() {  # <meta> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# 0 when the task's status stream still carries an OPEN context-rollover
# decision. This is the whole-stream fold in fm-classify-lib.sh, never the last
# line: an already-resolved rollover must never be run a second time, and a
# rollover event buried under later progress lines must still be found.
rollover_is_open() {  # <task-id>
  local id=$1 open
  open=$(status_open_decisions "$STATE/$id.status")
  [ -n "$open" ] || return 1
  printf '%s\n' "$open" | cut -f1 | grep -qxF "$ROLLOVER_KEY"
}

# Epoch seconds of the most recent line that OPENED the rollover key, using the
# status file's own modification time only as a floor. There is no per-line
# timestamp in the status protocol, so age is measured from the file that
# carries the open event; that is enough to separate "seconds old, still in
# flight" from "stalled".
rollover_open_since() {  # <task-id>
  local id=$1 f="$STATE/$1.status"
  [ -f "$f" ] || { printf '0'; return 0; }
  if date -r "$f" +%s 2>/dev/null; then return 0; fi
  stat -c %Y "$f" 2>/dev/null || printf '0'
}

record_path() { printf '%s/%s.rollover' "$STATE" "$1"; }

record_value() {  # <task-id> <key>
  meta_value "$(record_path "$1")" "$2"
}

write_record() {  # <task-id> <state> <predecessor> <predecessor-backend> <worktree> <successor>
  local id=$1 st=$2 pred=$3 pred_backend=$4 wt=$5 succ=$6 rec started
  rec=$(record_path "$id")
  started=$(record_value "$id" started_at)
  [ -n "$started" ] || started=$(date +%s)
  {
    echo "state=$st"
    echo "started_at=$started"
    echo "updated_at=$(date +%s)"
    echo "predecessor=$pred"
    echo "predecessor_backend=$pred_backend"
    echo "worktree=$wt"
    echo "successor=$succ"
  } > "$rec"
}

append_status() {  # <task-id> <line>
  printf '%s\n' "$2" >> "$STATE/$1.status"
}

# Load the task's recorded facts into globals and refuse anything a rollover
# cannot safely act on. A refusal here is a stop-and-report result: the
# predecessor is still holding the task, so nothing has been lost.
load_task() {  # <task-id>
  local id=$1
  META="$STATE/$id.meta"
  [ -f "$META" ] || die "no task record for $id at $META"
  KIND=$(meta_value "$META" kind)
  [ "$KIND" != secondmate ] || die "$id is a secondmate; a rollover carries a task worktree, not a home"
  PROJECT=$(meta_value "$META" project)
  WORKTREE=$(meta_value "$META" worktree)
  HARNESS=$(meta_value "$META" harness)
  REC_MODEL=$(meta_value "$META" model)
  REC_EFFORT=$(meta_value "$META" effort)
  BACKEND=$(fm_backend_of_meta "$META")
  ENDPOINT=$(fm_backend_target_of_meta "$META")
  [ -n "$PROJECT" ] || die "$id has no recorded project"
  [ -n "$WORKTREE" ] || die "$id has no recorded worktree; there is no preserved copy to carry across"
  [ -n "$ENDPOINT" ] || die "$id has no recorded endpoint; there is no session to retire"
  [ -f "$DATA/$id/brief.md" ] || die "$id has no brief at $DATA/$id/brief.md"
}

# The preserved copy must still be a real worktree root distinct from the
# project's primary checkout before anything is retired. fm-spawn.sh revalidates
# it at launch; checking here means a broken copy refuses while the predecessor
# is still alive rather than after it is gone.
assert_worktree_preserved() {  # <task-id>
  local wt_real proj_real wt_top
  wt_real=$(cd "$WORKTREE" 2>/dev/null && pwd -P) \
    || die "the preserved copy for $1 is gone: $WORKTREE"
  wt_top=$(git -C "$wt_real" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$wt_top" ] || die "the preserved copy for $1 is not a git worktree: $WORKTREE"
  wt_top=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top=
  [ "$wt_top" = "$wt_real" ] || die "the preserved copy for $1 is not a worktree root: $WORKTREE"
  proj_real=$(cd "$PROJECT" 2>/dev/null && pwd -P) || proj_real=$PROJECT
  [ "$wt_real" != "$proj_real" ] || die "the recorded copy for $1 is the primary checkout $PROJECT; refusing"
  WORKTREE_REAL=$wt_real
}

# The successor's own instructions. Written beside the task's original brief and
# never over it: the original stays the task contract, and this file carries the
# one thing that differs - continue an assignment already in flight, on a copy
# that already holds work, without redoing what the predecessor finished.
write_successor_brief() {  # <task-id>
  local id=$1 path envelope handoff
  path="$DATA/$id/successor-brief.md"
  envelope="$STATE/$id.envelope.json"
  handoff="$STATE/$id.handoff.json"
  {
    echo "# Successor brief - task $id"
    echo
    echo "You are the successor for a task already under way."
    echo "A previous worker on this task reached its context ceiling and was retired."
    echo "Its work is preserved and you continue it; you do not start over."
    echo
    echo "## Before anything else"
    echo
    echo "1. You are already in the preserved copy at \`$WORKTREE_REAL\`. Do not create another copy and do not move to the project checkout at \`$PROJECT\`."
    echo "2. Read the handoff envelope at \`$envelope\` if it exists. It carries the goal, constraints, progress, decisions, next steps, and the read and modified file lists."
    if [ -f "$envelope" ]; then
      echo "   The envelope exists. Restate its goal, every constraint, and its next action back before you touch anything, using the handoff tool's accept step when that tool is on your PATH."
    else
      echo "   No envelope was found at that path. Reconstruct state from the copy itself - \`git status\`, \`git log\`, and the uncommitted diff - and say plainly in your first status append that you had no envelope."
    fi
    echo "3. Check \`git status\` and \`git log\` in that copy before editing. Uncommitted changes there are the predecessor's unlanded work: preserve them, never reset, stash, or discard them."
    if [ -f "$handoff" ]; then
      echo "4. The handshake record at \`$handoff\` tracks this rollover. Close it through the handoff tool once you have restated, so the rollover is recorded as complete."
    fi
    echo
    echo "## Then"
    echo
    echo "Follow the task's original brief at \`$DATA/$id/brief.md\` from the point the envelope leaves off."
    echo "Everything in it still applies: the same task, the same acceptance criteria, the same delivery path, the same status protocol."
    echo
    echo "Append your first status line as soon as you have restated, so supervision can see the task is held again."
  } > "$path"
  SUCCESSOR_BRIEF=$path
}

cmd_status() {  # <task-id>
  local id=${1:-} st
  [ -n "$id" ] || die "status needs a task id"
  fm_task_id_creation_valid "$id" || die "invalid task id"
  load_task "$id"
  st=$(record_value "$id" state)
  echo "task=$id kind=$KIND backend=$BACKEND endpoint=$ENDPOINT"
  echo "worktree=$WORKTREE"
  echo "harness=$HARNESS model=${REC_MODEL:-default} effort=${REC_EFFORT:-default}"
  echo "last_attempt=${st:-none}"
  if rollover_is_open "$id"; then
    echo "rollover=open key=$ROLLOVER_KEY"
    return 0
  fi
  echo "rollover=none key=$ROLLOVER_KEY"
  return 3
}

cmd_run() {  # <task-id> [--harness|--model|--effort <value>]
  local id=${1:-} a
  local want='' harness_override='' model_override='' effort_override=''
  local spawn_out spawn_status new_wt
  local -a spawn_args
  [ -n "$id" ] || die "run needs a task id"
  shift || true
  fm_task_id_creation_valid "$id" || die "invalid task id"
  for a in "$@"; do
    if [ -n "$want" ]; then
      case "$want" in
        harness) harness_override=$a ;;
        model) model_override=$a ;;
        effort) effort_override=$a ;;
      esac
      want=
      continue
    fi
    case "$a" in
      --harness) want=harness ;;
      --harness=*) harness_override=${a#--harness=} ;;
      --model) want=model ;;
      --model=*) model_override=${a#--model=} ;;
      --effort) want=effort ;;
      --effort=*) effort_override=${a#--effort=} ;;
      *) die "unknown run option '$a'" ;;
    esac
  done
  [ -z "$want" ] || die "--$want requires a value"

  # A gate agent must never mutate the fleet, exactly as fm-spawn.sh refuses.
  fm_refuse_if_gate_agent

  load_task "$id"
  rollover_is_open "$id" \
    || die "$id has no open $ROLLOVER_KEY decision; a rollover runs only when the task's own status stream asks for one"
  assert_worktree_preserved "$id"

  [ -n "$harness_override" ] && HARNESS=$harness_override
  [ -n "$model_override" ] && REC_MODEL=$model_override
  [ -n "$effort_override" ] && REC_EFFORT=$effort_override
  [ -n "$HARNESS" ] || die "$id has no recorded harness and none was given"

  write_record "$id" starting "$ENDPOINT" "$BACKEND" "$WORKTREE_REAL" ""

  # Retire the predecessor FIRST. Two agents must never hold one copy, and a
  # window left running would keep reporting activity for a task it no longer
  # owns. The endpoint is removed; the copy, its commits, and its uncommitted
  # changes are untouched.
  fm_backend_kill "$BACKEND" "$ENDPOINT" "$(meta_value "$META" zellij_tab_id)" "fm-$id" 2>/dev/null || true
  if [ "$(fm_backend_agent_state "$BACKEND" "$ENDPOINT")" = alive ]; then
    write_record "$id" retire-failed "$ENDPOINT" "$BACKEND" "$WORKTREE_REAL" ""
    append_status "$id" "blocked [key=$ROLLOVER_KEY]: rollover could not retire the stopped session at $ENDPOINT; the task is still held by it and no successor was started"
    die "$id: the stopped session at $ENDPOINT is still alive; refusing to start a successor onto the same copy"
  fi
  write_record "$id" retired "$ENDPOINT" "$BACKEND" "$WORKTREE_REAL" ""

  write_successor_brief "$id"

  spawn_args=("$id" "$PROJECT" --harness "$HARNESS")
  # `default` is the recorded stand-in for "this harness got no explicit axis",
  # so it is carried as an absent flag rather than passed through as a literal.
  [ -z "$REC_MODEL" ] || [ "$REC_MODEL" = default ] || spawn_args+=(--model "$REC_MODEL")
  [ -z "$REC_EFFORT" ] || [ "$REC_EFFORT" = default ] || spawn_args+=(--effort "$REC_EFFORT")
  [ -z "$BACKEND" ] || spawn_args+=(--backend "$BACKEND")
  spawn_args+=(--adopt-worktree "$WORKTREE_REAL" --brief "$SUCCESSOR_BRIEF")
  [ "$KIND" != scout ] || spawn_args+=(--scout)
  set +e
  spawn_out=$("$FM_ROOT/bin/fm-spawn.sh" "${spawn_args[@]}" 2>&1)
  spawn_status=$?
  set -e
  if [ "$spawn_status" -ne 0 ]; then
    write_record "$id" spawn-failed "$ENDPOINT" "$BACKEND" "$WORKTREE_REAL" ""
    append_status "$id" "blocked [key=$ROLLOVER_KEY]: rollover retired the stopped session but the successor did not start; the preserved copy at $WORKTREE_REAL is intact and unheld"
    printf '%s\n' "$spawn_out" >&2
    die "$id: the successor failed to launch; the preserved copy at $WORKTREE_REAL is intact and no window holds the task"
  fi

  # The successor must be on the preserved copy, not a fresh one. fm-spawn.sh
  # already refuses a mismatch, so this is the second, independent check that the
  # record firstmate will act on from here really names that copy.
  new_wt=$(meta_value "$META" worktree)
  new_wt=$(cd "$new_wt" 2>/dev/null && pwd -P) || new_wt=
  if [ "$new_wt" != "$WORKTREE_REAL" ]; then
    write_record "$id" spawn-failed "$ENDPOINT" "$BACKEND" "$WORKTREE_REAL" "$(fm_backend_target_of_meta "$META")"
    append_status "$id" "blocked [key=$ROLLOVER_KEY]: rollover started a successor on '$new_wt' instead of the preserved copy $WORKTREE_REAL"
    die "$id: the successor landed on '$new_wt', not the preserved copy $WORKTREE_REAL"
  fi

  SUCCESSOR=$(fm_backend_target_of_meta "$META")
  write_record "$id" succeeded "$ENDPOINT" "$BACKEND" "$WORKTREE_REAL" "$SUCCESSOR"
  append_status "$id" "resolved [key=$ROLLOVER_KEY]: successor $SUCCESSOR holds the task on the preserved copy $WORKTREE_REAL; the stopped session $ENDPOINT was retired"
  printf '%s\n' "$spawn_out"
  echo "rollover $id predecessor=$ENDPOINT successor=$SUCCESSOR worktree=$WORKTREE_REAL"
}

# A rollover that never finishes is the failure this whole path exists to avoid:
# the predecessor is stopped or gone, no successor holds the task, and the fleet
# view shows nothing wrong. Report it once per poll cycle as one keyed line the
# caller can act on from the exit status alone.
cmd_audit() {
  local max_age=$AUDIT_DEFAULT_MAX_AGE a meta id now opened age st
  local want='' stalled=0
  local -a ids=()
  for a in "$@"; do
    if [ -n "$want" ]; then max_age=$a; want=; continue; fi
    case "$a" in
      --max-age-seconds) want=max-age ;;
      --max-age-seconds=*) max_age=${a#--max-age-seconds=} ;;
      -*) die "unknown audit option '$a'" ;;
      *) ids+=("$a") ;;
    esac
  done
  [ -z "$want" ] || die "--max-age-seconds requires a value"
  case "$max_age" in ''|*[!0-9]*) die "--max-age-seconds must be a whole number of seconds" ;; esac
  if [ "${#ids[@]}" -eq 0 ]; then
    for meta in "$STATE"/*.meta; do
      [ -e "$meta" ] || continue
      id=$(basename "$meta"); id=${id%.meta}
      ids+=("$id")
    done
  fi
  [ "${#ids[@]}" -gt 0 ] || return 0
  now=$(date +%s)
  for id in "${ids[@]+"${ids[@]}"}"; do
    [ -f "$STATE/$id.meta" ] || continue
    [ "$(meta_value "$STATE/$id.meta" kind)" != secondmate ] || continue
    rollover_is_open "$id" || continue
    opened=$(rollover_open_since "$id")
    age=$((now - opened))
    [ "$age" -ge "$max_age" ] || continue
    st=$(record_value "$id" state)
    stalled=1
    echo "ROLLOVER_STALLED: $id open for ${age}s with no successor holding the task (last attempt: ${st:-none}; preserved copy: $(meta_value "$STATE/$id.meta" worktree))"
  done
  [ "$stalled" -eq 0 ] || return 1
  return 0
}

case "${1:-}" in
  -h|--help|'') usage; [ -n "${1:-}" ] || exit 2; exit 0 ;;
  status) shift; cmd_status "$@" ;;
  run) shift; cmd_run "$@" ;;
  audit) shift; cmd_audit "$@" ;;
  *) die "unknown command '${1}'; expected status, run, or audit" ;;
esac
