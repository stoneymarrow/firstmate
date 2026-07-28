#!/usr/bin/env bash
# Behavior tests for bin/fm-intake.sh - Firstmate's chat adapter for captured
# work, its backlog handoff, and the shared autonomous-pickup gate.
#
# The classifier itself belongs to Launchpad and is never faked here: the tests
# that need it run against a real launchpad source tree and say so when one is
# not on this host. The refusal path, which must hold with no classifier at all,
# always runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-chat-capture)
INTAKE="$ROOT/bin/fm-intake.sh"

# --- a home whose launchpad clone does not exist ----------------------------

test_missing_classifier_refuses_and_files_nothing() {
  local home out rc
  home="$TMP_ROOT/no-classifier"
  mkdir -p "$home/config" "$home/data"
  printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$home/data/backlog.md"
  out=$(FM_HOME="$home" FM_LAUNCHPAD_ROOT="$TMP_ROOT/absent" \
    "$INTAKE" capture --text "Ship the thing" --class firstmate-work --confidence high 2>&1)
  rc=$?
  [ "$rc" -eq 3 ] || fail "expected exit 3 with no classifier, got $rc"
  assert_contains "$out" "autonomous pickup: off" \
    "a missing classifier did not report pickup as off"
  assert_contains "$out" "nothing was classified or filed" \
    "a missing classifier did not say that nothing was filed"
  assert_no_grep "^- \[ \] " "$home/data/backlog.md" \
    "a capture reached the backlog without the shared classifier"
  pass "fm-intake.sh: refuses and files nothing when the shared classifier is absent"
}

test_usage_errors() {
  local out rc
  out=$("$INTAKE" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "expected exit 2 for no command, got $rc"
  out=$("$INTAKE" drain 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "expected exit 2 for an unknown command, got $rc"
  assert_contains "$out" "unknown command" "an unknown command was not named"
  out=$(FM_LAUNCHPAD_ROOT="$TMP_ROOT/absent" "$INTAKE" capture 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "expected exit 2 for a capture with no text, got $rc"
  assert_contains "$out" "needs --text or --stdin" "an empty capture was not refused"
  pass "fm-intake.sh: refuses malformed invocations"
}

# --- everything below needs the real Launchpad classifier -------------------

find_launchpad() {
  local candidate
  for candidate in ${FM_LAUNCHPAD_ROOT:+"$FM_LAUNCHPAD_ROOT"} \
    "$ROOT/projects/launchpad" "$HOME/dev/firstmate/projects/launchpad"; do
    [ -f "$candidate/src/launchpad/pickup.py" ] || continue
    [ -f "$candidate/src/launchpad/classify.py" ] || continue
    [ -f "$candidate/src/launchpad/intake.py" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# One fixture vault plus one fixture firstmate home. Nothing here touches the
# captain's own vault: Launchpad's documented LAUNCHPAD_VAULT / LAUNCHPAD_DATA /
# LAUNCHPAD_CONFIG overrides point every write into the temp root.
new_fixture() {
  local name=$1 base
  mkdir -p "$TMP_ROOT/$name"
  base=$(cd "$TMP_ROOT/$name" && pwd)
  mkdir -p "$base/vault/Projects" "$base/vault/TaskNotes/Tasks" \
    "$base/vault/Reading" "$base/vault/Notes" "$base/data" \
    "$base/home/config" "$base/home/data"
  printf '# Inbox\n\n' > "$base/vault/Inbox.md"
  printf '# Firstmate\n' > "$base/vault/Projects/Firstmate.md"
  printf '# Reading Inbox\n\n## Inbox\n\n' > "$base/vault/Reading/Reading Inbox.md"
  printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$base/home/data/backlog.md"
  printf '[fleet]\narmed = false\n\n[vault]\npath = "%s/vault"\n\n[data]\npath = "%s/data"\n' \
    "$base" "$base" > "$base/config.toml"
  printf '%s\n' "$base"
}

run_intake() {
  local base=$1
  shift
  FM_HOME="$base/home" FM_LAUNCHPAD_ROOT="$LAUNCHPAD" \
    LAUNCHPAD_CONFIG="$base/config.toml" "$INTAKE" "$@" 2>&1
}

test_pickup_value_is_visible_and_off_by_default() {
  local base out
  base=$(new_fixture pickup-visible)
  out=$(run_intake "$base" pickup) || fail "pickup reported a failure: $out"
  assert_contains "$out" "autonomous pickup: off" "pickup did not default to off"
  assert_contains "$out" "declaration absent" "pickup did not say why it was off"
  assert_contains "$out" "$base/home/config/autonomous-pickup" \
    "pickup did not name the declaration file it consulted"
  pass "fm-intake.sh: the pickup value and its cause are visible, and default off"
}

test_firstmate_work_is_queued_and_held_while_pickup_is_off() {
  local base out backlog
  base=$(new_fixture pickup-off)
  backlog="$base/home/data/backlog.md"
  out=$(run_intake "$base" capture --text "Add a retry to the fleet sync script" \
    --class firstmate-work --confidence high) || fail "capture failed: $out"
  assert_contains "$out" "held for the captain" "an ineligible capture was not held"
  assert_grep "hold-kind: captain" "$backlog" "the backlog item carries no captain hold"
  assert_grep "source-id: " "$backlog" "the backlog item lost its stable source identity"
  out=$(tasks-axi ready --file "$backlog" 2>&1)
  assert_contains "$out" "count: 0" \
    "a capture made while pickup was off showed up as ready work"
  pass "fm-intake.sh: with pickup off a Firstmate-work capture is recorded and held, never ready"
}

test_pickup_on_makes_only_high_confidence_firstmate_work_eligible() {
  local base out backlog
  base=$(new_fixture pickup-on)
  backlog="$base/home/data/backlog.md"
  printf 'on\n' > "$base/home/config/autonomous-pickup"
  out=$(run_intake "$base" capture --text "Bump the shellcheck pin in CI" \
    --class firstmate-work --confidence high) || fail "capture failed: $out"
  assert_contains "$out" "autonomous pickup: on" "the on declaration was not read as on"
  assert_contains "$out" "dispatch allowed by the pickup declaration" \
    "an eligible capture was not reported as dispatchable"
  out=$(run_intake "$base" capture --text "Renew the passport" \
    --class task --confidence high) || fail "capture failed: $out"
  assert_not_contains "$out" "dispatch allowed" \
    "a personal task became dispatchable while pickup was on"
  out=$(run_intake "$base" capture --text "Something about the watcher maybe" \
    --class firstmate-work --confidence low) || fail "capture failed: $out"
  assert_contains "$out" "retained in Inbox.md" \
    "a low-confidence Firstmate capture was not retained"
  assert_not_contains "$out" "dispatch allowed" \
    "a low-confidence capture became dispatchable while pickup was on"
  out=$(tasks-axi ready --file "$backlog" 2>&1)
  assert_contains "$out" "intake-bump-the-shellcheck-pin" \
    "the one eligible capture is not ready work"
  assert_not_contains "$out" "renew-the-passport" \
    "a personal task reached the Firstmate work queue"
  pass "fm-intake.sh: pickup on starts only high-confidence Firstmate-owned work"
}

test_bad_declarations_all_behave_as_off() {
  local base out backlog decl
  base=$(new_fixture pickup-bad)
  backlog="$base/home/data/backlog.md"
  decl="$base/home/config/autonomous-pickup"

  printf 'yes please\n' > "$decl"
  out=$(run_intake "$base" capture --text "Cache the fleet snapshot" \
    --class firstmate-work --confidence high) || fail "capture failed: $out"
  assert_contains "$out" "autonomous pickup: off" "a malformed declaration was not off"
  assert_contains "$out" "held for the captain" "a malformed declaration left work unheld"

  printf 'on\n' > "$decl"
  chmod 000 "$decl"
  out=$(run_intake "$base" capture --text "Rotate the log files" \
    --class firstmate-work --confidence high)
  chmod 644 "$decl"
  assert_contains "$out" "autonomous pickup: off" "an unreadable declaration was not off"
  assert_contains "$out" "held for the captain" "an unreadable declaration left work unheld"

  rm -f "$decl"
  mkdir -p "$decl"
  out=$(run_intake "$base" pickup)
  rmdir "$decl"
  assert_contains "$out" "autonomous pickup: off" "a directory declaration was not off"

  out=$(tasks-axi ready --file "$backlog" 2>&1)
  assert_contains "$out" "count: 0" \
    "a bad declaration let a capture become ready work"
  pass "fm-intake.sh: missing, malformed and unreadable declarations all behave as off"
}

test_every_class_reaches_its_own_destination() {
  local base out
  base=$(new_fixture classes)
  out=$(run_intake "$base" capture --text "Book the dentist" \
    --class task --confidence high) || fail "capture failed: $out"
  assert_contains "$out" "-> task-note" "a personal task did not land on a TaskNote"
  out=$(run_intake "$base" capture --text "Read the SEBI circular on anchor lock-in" \
    --class reading --confidence high) || fail "capture failed: $out"
  assert_contains "$out" "-> reading-inbox" "a reading item did not land in the Reading Inbox"
  out=$(run_intake "$base" capture --text "SME anchor lock-in runs thirty days" \
    --class note --confidence high --topic Markets) || fail "capture failed: $out"
  assert_contains "$out" "-> topic-note" "a durable note did not land on a topic note"
  out=$(run_intake "$base" capture --text "maybe do something about the thing" \
    --class banana --confidence high) || fail "capture failed: $out"
  assert_contains "$out" "retained in Inbox.md" "an unplaceable capture was not retained"
  assert_grep "unresolved capture" "$base/vault/Inbox.md" \
    "the retained capture is not marked in Inbox.md"
  assert_no_grep "Daily" "$base/home/data/backlog.md" "a capture routed to a daily note"
  [ ! -d "$base/vault/Daily" ] || fail "intake created a daily-note directory"
  pass "fm-intake.sh: task, reading, note and ambiguous captures each reach their own home"
}

test_duplicate_chat_capture_links_to_one_item() {
  local base out backlog count
  base=$(new_fixture duplicate)
  backlog="$base/home/data/backlog.md"
  out=$(run_intake "$base" capture --text "Add a retry to the fleet sync script" \
    --class firstmate-work --confidence high) || fail "first capture failed: $out"
  assert_contains "$out" "-> backlog" "the first capture did not reach the backlog"
  out=$(run_intake "$base" capture --text "Add   a retry to the fleet sync script  " \
    --class firstmate-work --confidence high) || fail "second capture failed: $out"
  assert_contains "$out" "linked:" "the duplicate capture did not link to the first"
  count=$(grep -c "^- \[ \] intake-" "$backlog")
  [ "$count" -eq 1 ] || fail "the duplicate capture created $count backlog items, expected 1"
  pass "fm-intake.sh: the same words captured twice link to one item"
}

test_inbox_capture_and_chat_capture_link_to_one_item() {
  local base out filed
  base=$(new_fixture cross-entry)
  # File the same words through Launchpad's own Inbox path first, using its
  # documented structure seam, then capture them again from chat.
  filed=$(PYTHONPATH="$LAUNCHPAD/src" LAUNCHPAD_CONFIG="$base/config.toml" \
    "$PYBIN" - "$base" <<'PY'
import sys
from pathlib import Path
from launchpad import config, intake
base = Path(sys.argv[1])
cfg = config.load_config()
res = intake.file_items(config.vault_root(cfg), config.data_dir(cfg),
                        [{"text": "Add a retry to the fleet sync script",
                          "type": "firstmate-work", "confidence": "high"}],
                        origin="inbox", pickup_config=cfg)
print(len(res["filed"]))
PY
  ) || fail "the inbox-side capture could not be filed: $filed"
  [ "$filed" = 1 ] || fail "expected the inbox capture to file 1 item, got '$filed'"
  out=$(run_intake "$base" capture --text "Add a retry to the fleet sync script" \
    --class firstmate-work --confidence high) || fail "chat capture failed: $out"
  assert_contains "$out" "linked:" \
    "a chat capture of words already in the Inbox created a second item"
  pass "fm-intake.sh: an Inbox capture and the same chat capture link to one item"
}

test_manual_backlog_backend_refuses_loudly() {
  local base out rc
  base=$(new_fixture manual-backend)
  printf 'manual\n' > "$base/home/config/backlog-backend"
  out=$(run_intake "$base" capture --text "Manual backend capture check" \
    --class firstmate-work --confidence high)
  rc=$?
  [ "$rc" -eq 4 ] || fail "expected exit 4 when the backlog handoff cannot run, got $rc"
  assert_contains "$out" "add it by hand" "the manual handoff step was not named"
  assert_not_contains "$out" "dispatch allowed" \
    "an unhanded-off capture was reported as dispatchable"
  pass "fm-intake.sh: a backlog backend that cannot take the handoff refuses loudly"
}

test_missing_classifier_refuses_and_files_nothing
test_usage_errors

if ! LAUNCHPAD=$(find_launchpad); then
  echo "skip: no launchpad source tree with the intake classifier (set FM_LAUNCHPAD_ROOT)"
  exit 0
fi
command -v tasks-axi > /dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
if [ -x "$LAUNCHPAD/.venv/bin/python" ]; then
  PYBIN="$LAUNCHPAD/.venv/bin/python"
elif command -v python3 > /dev/null 2>&1; then
  PYBIN=python3
else
  echo "skip: no python3 to run the shared intake classifier"
  exit 0
fi

test_pickup_value_is_visible_and_off_by_default
test_firstmate_work_is_queued_and_held_while_pickup_is_off
test_pickup_on_makes_only_high_confidence_firstmate_work_eligible
test_bad_declarations_all_behave_as_off
test_every_class_reaches_its_own_destination
test_duplicate_chat_capture_links_to_one_item
test_inbox_capture_and_chat_capture_link_to_one_item
test_manual_backlog_backend_refuses_loudly
