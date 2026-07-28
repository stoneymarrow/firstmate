#!/usr/bin/env bash
# fm-intake.sh - Firstmate's chat adapter for captured work: Launchpad's
# canonical intake classifier, the backlog handoff, and the guarded
# autonomous-pickup gate.
#
# A capture is something the captain hands over rather than commissions. This
# script never starts work. It classifies one capture through the SAME Launchpad
# classifier the Inbox drain uses, so a capture typed in chat and the same words
# typed into Inbox.md produce one item and not two, then hands Firstmate-owned
# work to the backlog. Whether that item may be dispatched without asking the
# captain is decided by one shared declaration file, and by nothing here.
#
# Usage:
#   fm-intake.sh pickup
#   fm-intake.sh capture --text "<the captain's words>" [proposal flags]
#   fm-intake.sh capture --stdin [proposal flags]
#
# Proposal flags (all optional; the Firstmate chat agent proposes, Launchpad
# decides - an unknown class or an unstated confidence is retained, never
# guessed). With none of them the capture is structured by Launchpad's own
# intake agent instead:
#   --class <task|firstmate-work|note|idea|question|reading|initiative>
#   --confidence <high|low>   Firstmate-owned work must state high to be queued
#   --project <name>          must resolve to a real project note
#   --topic <name>  --name <project title>  --date <YYYY-MM-DD>  --backlog
#   --items <json>            a full Launchpad proposal list, for a batch
#
# Other options:
#   --vault-root <path>  --data-dir <path>
#                   run against a fixture vault instead of the captain's own
#                   (passed straight to Launchpad's LAUNCHPAD_VAULT /
#                   LAUNCHPAD_DATA overrides; Launchpad owns the resolution)
#   --backlog-file <path>  write the handoff to this backlog instead of
#                   $FM_HOME/data/backlog.md
#   --json <path>   also write the full Launchpad result as JSON
#   -h, --help      print this header
#
# The autonomous-pickup declaration is one file holding one word, `on` or `off`,
# at $FM_HOME/config/autonomous-pickup. Launchpad's `launchpad.pickup` module is
# its single reader and this script never second-guesses it: absent, unreadable,
# malformed or any word other than `on` is off, and off means every captured
# item lands held for the captain. See docs/configuration.md.
#
# Exit status:
#   0  the capture was classified and every handoff landed
#   2  usage error
#   3  the shared classifier or declaration could not be reached; nothing filed
#   4  the capture was filed but the backlog handoff did not land

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-intake: %s\n' "$*" >&2
  exit 2
}

MODE=
TEXT=
READ_STDIN=0
BACKLOG_FILE=
JSON_OUT=
BRIDGE_ARGS=()

[ "$#" -gt 0 ] || { usage; exit 2; }
case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  pickup | capture)
    MODE=$1
    shift
    ;;
  *)
    die "unknown command '$1' (expected pickup or capture)"
    ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --text)
      [ "$#" -gt 1 ] || die "--text requires the capture text"
      TEXT=$2
      shift 2
      ;;
    --stdin)
      READ_STDIN=1
      shift
      ;;
    --class | --confidence | --project | --topic | --name | --date | --items)
      [ "$#" -gt 1 ] || die "$1 requires a value"
      BRIDGE_ARGS+=("$1" "$2")
      shift 2
      ;;
    --backlog)
      BRIDGE_ARGS+=(--backlog)
      shift
      ;;
    --vault-root)
      [ "$#" -gt 1 ] || die "--vault-root requires a path"
      export LAUNCHPAD_VAULT=$2
      shift 2
      ;;
    --data-dir)
      [ "$#" -gt 1 ] || die "--data-dir requires a path"
      export LAUNCHPAD_DATA=$2
      shift 2
      ;;
    --backlog-file)
      [ "$#" -gt 1 ] || die "--backlog-file requires a path"
      BACKLOG_FILE=$2
      shift 2
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires an output path"
      JSON_OUT=$2
      shift 2
      ;;
    *)
      die "unknown option '$1'"
      ;;
  esac
done

[ -n "$BACKLOG_FILE" ] || BACKLOG_FILE="$FM_HOME/data/backlog.md"

if [ "$READ_STDIN" -eq 1 ]; then
  TEXT=$(cat)
fi

if [ "$MODE" = capture ] && [ -z "${TEXT//[[:space:]]/}" ]; then
  die "capture needs --text or --stdin"
fi

# The classifier and the declaration reader are Launchpad's, deliberately. When
# its source tree is not reachable there is no second implementation to fall
# back to, and inventing one is the drift this contract exists to prevent.
launchpad_root() {
  local candidates=() candidate
  [ -z "${FM_LAUNCHPAD_ROOT:-}" ] || candidates+=("$FM_LAUNCHPAD_ROOT")
  candidates+=("$FM_HOME/projects/launchpad" "$FM_ROOT/projects/launchpad")
  for candidate in "${candidates[@]}"; do
    [ -f "$candidate/src/launchpad/pickup.py" ] || continue
    [ -f "$candidate/src/launchpad/classify.py" ] || continue
    (cd "$candidate" && pwd)
    return 0
  done
  return 1
}

launchpad_python() {
  local root=$1
  if [ -x "$root/.venv/bin/python" ]; then
    printf '%s\n' "$root/.venv/bin/python"
    return 0
  fi
  if command -v python3 > /dev/null 2>&1; then
    printf '%s\n' python3
    return 0
  fi
  return 1
}

unavailable() {
  printf 'autonomous pickup: off - %s\n' "$1"
  printf 'fm-intake: nothing was classified or filed.\n' >&2
  exit 3
}

LP_ROOT=$(launchpad_root) || unavailable \
  "the shared intake classifier is not on this host; expected a launchpad clone at $FM_HOME/projects/launchpad"
LP_PY=$(launchpad_python "$LP_ROOT") || unavailable \
  "no python3 is available to reach the shared intake classifier"

TMPDIR_RUN=$(mktemp -d "${TMPDIR:-/tmp}/fm-intake.XXXXXX") || die "cannot create a working directory"
trap 'rm -rf -- "$TMPDIR_RUN"' EXIT HUP INT TERM
RECORDS="$TMPDIR_RUN/records.tsv"

BRIDGE_CMD=("$LP_PY" "$SCRIPT_DIR/fm-intake-bridge.py" "$MODE")
[ "$MODE" = capture ] && BRIDGE_CMD+=(--text "$TEXT")
[ "${#BRIDGE_ARGS[@]}" -eq 0 ] || BRIDGE_CMD+=("${BRIDGE_ARGS[@]}")
[ -z "$JSON_OUT" ] || BRIDGE_CMD+=(--json-out "$JSON_OUT")

PYTHONPATH="$LP_ROOT/src${PYTHONPATH:+:$PYTHONPATH}" "${BRIDGE_CMD[@]}" \
  > "$RECORDS" 2> "$TMPDIR_RUN/stderr" < /dev/null
BRIDGE_STATUS=$?

PICKUP_LINE=
while IFS=$'\t' read -r kind f2 f3 _rest; do
  case "$kind" in
    pickup)
      # Field 2 is Launchpad's on/off word; field 3 is the whole visible line,
      # value and cause together, which is what the operator needs to see.
      PICKUP_LINE=$f3
      ;;
    error)
      printf 'autonomous pickup: off - the shared intake classifier refused: %s %s\n' "$f2" "$f3"
      [ ! -s "$TMPDIR_RUN/stderr" ] || cat "$TMPDIR_RUN/stderr" >&2
      printf 'fm-intake: nothing was classified or filed.\n' >&2
      exit 3
      ;;
  esac
done < "$RECORDS"

if [ "$BRIDGE_STATUS" -ne 0 ] || [ -z "$PICKUP_LINE" ]; then
  [ ! -s "$TMPDIR_RUN/stderr" ] || cat "$TMPDIR_RUN/stderr" >&2
  unavailable "the shared intake classifier exited $BRIDGE_STATUS"
fi

printf 'autonomous pickup: %s\n' "$PICKUP_LINE"
[ "$MODE" = capture ] || exit 0

# One backlog id per capture identity, so the same words captured twice reach the
# same item. `tasks-axi add` is idempotent on the id and reports `already`, which
# is how a chat capture links to an Inbox twin instead of creating a second task.
backlog_id() {
  local sid=$1 text=$2 slug
  slug=$(printf '%s' "$text" |
    tr '[:upper:]' '[:lower:]' |
    tr -c 'a-z0-9' '-' |
    tr -s '-' |
    cut -c1-24)
  slug=${slug#-}
  slug=${slug%-}
  [ -n "$slug" ] || slug=capture
  printf 'intake-%s-%s\n' "$slug" "$(printf '%s' "$sid" | cut -c1-6)"
}

backlog_title() {
  # tasks-axi's markdown backend reads `(key: value)` suffixes as fields, so the
  # title carries no brackets. The captain's exact words are never edited away:
  # they stay in the vault note and in the item body.
  printf '%s' "$1" | tr -d '()[]' | cut -c1-96
}

HANDOFF_STATUS=0
HANDOFF_AVAILABLE=1
if ! fm_tasks_axi_backend_available "$CONFIG_DIR"; then
  HANDOFF_AVAILABLE=0
fi

while IFS=$'\t' read -r kind sid cls dest eligible path text; do
  case "$kind" in
    filed) ;;
    linked)
      # linked records carry the already-filed path where filed carries the
      # destination, so a duplicate chat capture names the one item it joined.
      printf 'linked: %s - already captured, now at %s\n' "$cls" "$dest"
      continue
      ;;
    retained)
      # retained records carry the routing reason in the same position.
      printf 'retained in Inbox.md: %s\n' "$dest"
      continue
      ;;
    *)
      continue
      ;;
  esac

  if [ "$dest" != tasks-axi ]; then
    printf 'filed: %s -> %s at %s\n' "$cls" "$dest" "$path"
    continue
  fi

  ID=$(backlog_id "$sid" "$text")
  TITLE=$(backlog_title "$text")
  BODY="captured from chat; source-id: $sid; class: $cls; vault note: $path"

  if [ "$HANDOFF_AVAILABLE" -eq 0 ]; then
    printf 'filed: %s -> vault note %s\n' "$cls" "$path"
    printf 'fm-intake: the backlog handoff needs compatible tasks-axi and a tasks-axi backlog backend.\n' >&2
    printf 'fm-intake: add it by hand as queued and held, id %s, title %s\n' "$ID" "$TITLE" >&2
    HANDOFF_STATUS=4
    continue
  fi

  if ! ADD_OUT=$(tasks-axi add "$ID" "$TITLE" --file "$BACKLOG_FILE" \
    --kind ship --body "$BODY" --json 2>&1 < /dev/null); then
    printf 'fm-intake: backlog handoff failed for %s: %s\n' "$ID" "$ADD_OUT" >&2
    HANDOFF_STATUS=4
    continue
  fi

  QUEUE_NOTE=queued
  case "$ADD_OUT" in
    *'"already"'*) QUEUE_NOTE="already queued" ;;
  esac

  if [ "$eligible" = 1 ]; then
    printf 'filed: %s -> backlog %s, %s, dispatch allowed by the pickup declaration\n' \
      "$cls" "$ID" "$QUEUE_NOTE"
    continue
  fi

  # Not eligible means the shared declaration did not say `on`. The item is not
  # merely reported as ineligible, it is recorded as held, so nothing downstream
  # can pick it up as ready work.
  if ! HOLD_OUT=$(tasks-axi hold "$ID" --file "$BACKLOG_FILE" \
    --reason "autonomous pickup is off so this capture waits for the captain" \
    --kind captain --json 2>&1 < /dev/null); then
    printf 'fm-intake: could not hold %s: %s\n' "$ID" "$HOLD_OUT" >&2
    HANDOFF_STATUS=4
    continue
  fi
  printf 'filed: %s -> backlog %s, %s, held for the captain\n' "$cls" "$ID" "$QUEUE_NOTE"
done < "$RECORDS"

exit "$HANDOFF_STATUS"
