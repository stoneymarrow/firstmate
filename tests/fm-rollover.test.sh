#!/usr/bin/env bash
# Behavior tests for the context-rollover handler (bin/fm-rollover.sh) and the
# worktree-adopt launch path it depends on (bin/fm-spawn.sh --adopt-worktree).
#
# The gap these close: the external context sensor stops a crewmate at its hard
# ceiling and appends `blocked [key=context-rollover]: ... start a successor on
# this task's existing worktree and retire this session`, but firstmate had no
# way to carry that out. Every ship spawn ran `treehouse get` and asserted a
# FRESH worktree, so launching onto the preserved copy was impossible.
#
# A fake tmux stands in for the session provider: it logs every subcommand so the
# tests can prove the predecessor window was killed and that `treehouse get` was
# never sent on the adopt path, and it answers `#{pane_current_path}` from an
# env var so the spawn settle loop resolves deterministically.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
ROLLOVER="$ROOT/bin/fm-rollover.sh"
TMP_ROOT=$(fm_test_tmproot fm-rollover)

# The exact line the deployed sensor appends at its hard handoff
# (context/lib/fm_context/signal.py HARD_LINE). Reproduced verbatim so the
# handler is proven against the real wire text, not a paraphrase.
SENSOR_HARD_LINE='blocked [key=context-rollover]: context hard handoff reached; no further investigative, implementation, or validation tool calls in this window - start a successor on this task'"'"'s existing worktree and retire this session'
# The line the handoff actuator appends when it offers the envelope
# (handoff/lib/fm_handoff/handshake.py OFFERED_LINE).
ACTUATOR_OFFERED_LINE='blocked [key=context-rollover]: handoff offered; start a successor on this task'"'"'s existing worktree - it must restate goal, constraints, and next action from the envelope'

make_fakebin() {  # <case-dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # The window registry is what makes retire-then-relaunch testable: the real
  # adapter refuses to create a window that already exists and reads the same
  # listing to decide whether an endpoint is still there, so both halves of a
  # rollover depend on that listing actually changing.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TMUX_LOG:?FM_FAKE_TMUX_LOG unset}
reg=${FM_FAKE_TMUX_WINDOWS:?FM_FAKE_TMUX_WINDOWS unset}
printf '%s\n' "$*" >> "$log"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ -f "$reg" ] && cat "$reg"; exit 0 ;;
  list-panes) exit 0 ;;
  new-window)
    name=
    prev=
    for a in "$@"; do
      [ "$prev" = -n ] && name=$a
      prev=$a
    done
    [ -z "$name" ] || printf '%s\n' "$name" >> "$reg"
    n=0
    [ -f "$reg" ] && n=$(grep -c . "$reg")
    printf '@%s\n' "$n"
    exit 0
    ;;
  kill-window) : > "$reg"; exit 0 ;;
  has-session|new-session) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # treehouse must exist so the non-adopt control path can run, and must be
  # loud in the log so an adopt spawn calling it would be caught.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> builds a home, a project repo, and a real worktree of
# that project standing in for the task's preserved copy.
make_case() {  # <name> <task-id>
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_DIR=$case_dir
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  OTHER_WT_DIR="$case_dir/other-repo-wt"
  FAKEBIN=$(make_fakebin "$case_dir/fake")
  TMUX_LOG="$case_dir/tmux.log"
  WINDOW_REG="$case_dir/tmux-windows"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_git_init_commit "$OTHER_WT_DIR"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'original brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  touch "$HOME_DIR/state/.last-watcher-beat" "$TMUX_LOG" "$WINDOW_REG"
  PANE_PATH=$WT_DIR
  SETTLE_POLLS=
  # The physical form every path comparison inside fm-spawn and fm-rollover
  # uses; on macOS the fixture root reaches these scripts through /private.
  WT_REAL=$(cd "$WT_DIR" && pwd -P)
}

fm_env() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_TMUX_WINDOWS="$WINDOW_REG" \
    FM_FAKE_PANE_PATH="$PANE_PATH" FM_SPAWN_SETTLE_POLLS="$SETTLE_POLLS" \
    PATH="$FAKEBIN:$PATH" "$@"
}

run_spawn() { PANE_PATH=$1; shift; fm_env "$SPAWN" "$@" 2>&1; }
run_rollover() { fm_env "$ROLLOVER" "$@" 2>&1; }

# Stand up a predecessor: a real spawn onto a fresh worktree, then rewrite its
# recorded worktree to the fixture copy so the rollover has a stable target.
seed_predecessor() {  # <task-id>
  local id=$1 out
  out=$(run_spawn "$WT_DIR" "$id" "$PROJ_DIR")
  assert_contains "$out" "spawned $id" "predecessor spawn failed: $out"
  : > "$TMUX_LOG"
}

# --- fm-spawn.sh --adopt-worktree -------------------------------------------

test_adopt_launches_into_the_existing_copy_without_allocating_one() {
  local out
  make_case adopt-basic adopt-basic-a1
  out=$(run_spawn "$WT_DIR" adopt-basic-a1 "$PROJ_DIR" --adopt-worktree "$WT_DIR")
  expect_code 0 $? "adopt spawn should succeed"
  assert_contains "$out" "spawned adopt-basic-a1" "adopt spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/adopt-basic-a1.meta" \
    "meta did not record the adopted worktree"
  assert_no_grep 'treehouse' "$TMUX_LOG" \
    "an adopt spawn must never allocate a fresh copy with treehouse get"
  assert_grep "cd '$WT_REAL'" "$TMUX_LOG" "the pane was not moved into the adopted copy"
  pass "--adopt-worktree launches into the existing copy and never runs treehouse get"
}

test_adopt_refuses_the_primary_checkout() {
  local out status
  make_case adopt-primary adopt-primary-a2
  out=$(run_spawn "$PROJ_DIR" adopt-primary-a2 "$PROJ_DIR" --adopt-worktree "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "adopting the primary checkout must refuse"
  assert_contains "$out" "is the primary checkout" "refusal did not name the primary checkout"
  assert_absent "$HOME_DIR/state/adopt-primary-a2.meta" "a refused adopt spawn must record no task"
  pass "--adopt-worktree refuses the project's primary checkout"
}

test_adopt_refuses_a_worktree_of_another_repository() {
  local out status
  make_case adopt-foreign adopt-foreign-a3
  out=$(run_spawn "$OTHER_WT_DIR" adopt-foreign-a3 "$PROJ_DIR" --adopt-worktree "$OTHER_WT_DIR")
  status=$?
  expect_code 1 "$status" "adopting another repository's checkout must refuse"
  assert_contains "$out" "belongs to a different repository" \
    "refusal did not name the repository mismatch"
  pass "--adopt-worktree refuses a real worktree of a different repository"
}

test_adopt_refuses_when_the_pane_never_reaches_the_named_copy() {
  local out status
  make_case adopt-nosettle adopt-nosettle-a4
  # The pane reports a real, distinct worktree - but not the adopted one. The
  # settle loop accepted any non-project path, which is how a failed cd would
  # otherwise be recorded as success.
  SETTLE_POLLS=2
  out=$(run_spawn "$OTHER_WT_DIR" adopt-nosettle-a4 "$PROJ_DIR" --adopt-worktree "$WT_DIR")
  status=$?
  expect_code 1 "$status" "a pane that never reached the adopted copy must refuse"
  assert_contains "$out" "did not settle in the adopted worktree" \
    "refusal did not name the settle failure"
  pass "--adopt-worktree refuses when the pane settles anywhere but the named copy"
}

test_brief_override_is_confined_to_the_task_data_directory() {
  local out status
  make_case brief-escape brief-escape-a5
  printf 'elsewhere\n' > "$CASE_DIR/outside-brief.md"
  out=$(run_spawn "$WT_DIR" brief-escape-a5 "$PROJ_DIR" \
    --adopt-worktree "$WT_DIR" --brief "$CASE_DIR/outside-brief.md")
  status=$?
  expect_code 1 "$status" "a brief outside the task data directory must refuse"
  assert_contains "$out" "--brief must be a file inside" "refusal did not name the confinement rule"
  pass "--brief refuses a file outside data/<task-id>/"
}

# --- fm-rollover.sh run ------------------------------------------------------

test_rollover_refuses_without_an_open_decision() {
  local out status
  make_case no-open no-open-b1
  seed_predecessor no-open-b1
  printf 'working: ordinary progress\n' > "$HOME_DIR/state/no-open-b1.status"
  out=$(run_rollover run no-open-b1)
  status=$?
  expect_code 1 "$status" "a rollover with no open decision must refuse"
  assert_contains "$out" "no open context-rollover decision" "refusal did not name the missing decision"
  assert_no_grep 'kill-window' "$TMUX_LOG" "a refused rollover must not retire the session"
  pass "run refuses unless the task's own status stream carries an open rollover"
}

test_rollover_refuses_an_already_resolved_decision() {
  local out status
  make_case resolved resolved-b2
  seed_predecessor resolved-b2
  {
    printf '%s\n' "$SENSOR_HARD_LINE"
    printf 'resolved [key=context-rollover]: handoff closed; successor holds the task\n'
  } > "$HOME_DIR/state/resolved-b2.status"
  out=$(run_rollover run resolved-b2)
  status=$?
  expect_code 1 "$status" "an already-resolved rollover must not run again"
  assert_contains "$out" "no open context-rollover decision" "refusal did not name the missing decision"
  pass "run refuses a rollover that a later resolved event already closed"
}

test_rollover_refuses_when_the_preserved_copy_is_gone() {
  local out status
  make_case gone gone-b3
  seed_predecessor gone-b3
  printf '%s\n' "$SENSOR_HARD_LINE" > "$HOME_DIR/state/gone-b3.status"
  rm -rf "$WT_DIR"
  out=$(run_rollover run gone-b3)
  status=$?
  expect_code 1 "$status" "a rollover with no preserved copy must refuse"
  assert_contains "$out" "preserved copy" "refusal did not name the missing copy"
  assert_no_grep 'kill-window' "$TMUX_LOG" \
    "a rollover must not retire the session before proving the copy survives"
  pass "run refuses while the preserved copy cannot be proven intact"
}

# The whole point: the sensor's own hard-handoff line arrives, firstmate retires
# the stopped window and starts one successor on the SAME copy.
test_rollover_retires_the_session_and_succeeds_on_the_same_copy() {
  local out status meta_before meta_after
  make_case success success-b4
  seed_predecessor success-b4
  meta_before=$(grep '^window=' "$HOME_DIR/state/success-b4.meta")
  printf '%s\n' "$SENSOR_HARD_LINE" > "$HOME_DIR/state/success-b4.status"

  out=$(run_rollover run success-b4)
  status=$?
  expect_code 0 "$status" "the rollover should succeed: $out"
  assert_contains "$out" "rollover success-b4" "rollover did not report its outcome"

  assert_grep 'kill-window' "$TMUX_LOG" "the stopped session was not retired"
  assert_no_grep 'treehouse' "$TMUX_LOG" \
    "the successor must continue on the preserved copy, never a freshly allocated one"

  meta_after=$(grep '^worktree=' "$HOME_DIR/state/success-b4.meta")
  assert_contains "$meta_after" "worktree=$WT_DIR" "the successor is not on the preserved copy"

  assert_grep "state=succeeded" "$HOME_DIR/state/success-b4.rollover" \
    "the durable rollover record does not show success"
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/success-b4.rollover" \
    "the durable rollover record does not name the preserved copy"

  assert_grep 'resolved [key=context-rollover]' "$HOME_DIR/state/success-b4.status" \
    "the rollover decision was never closed"

  assert_present "$HOME_DIR/data/success-b4/successor-brief.md" "no successor brief was written"
  assert_grep "$WT_REAL" "$HOME_DIR/data/success-b4/successor-brief.md" \
    "the successor brief does not name the preserved copy"
  assert_grep "brief.md" "$HOME_DIR/data/success-b4/successor-brief.md" \
    "the successor brief does not point back at the task's original brief"
  assert_grep 'original brief' "$HOME_DIR/data/success-b4/brief.md" \
    "the task's original brief must never be overwritten"
  printf '%s' "$meta_before" > /dev/null
  pass "a sensor hard-handoff event is cleared by retiring the session and succeeding on the same copy"
}

# With a handoff envelope beside the task, the successor is told to restate from
# it before touching anything; without one it is told to say so rather than
# quietly inventing the predecessor's state.
test_successor_brief_tracks_whether_an_envelope_exists() {
  local out
  make_case envelope envelope-b7
  seed_predecessor envelope-b7
  printf '{"envelope_version":1,"task_id":"envelope-b7"}\n' > "$HOME_DIR/state/envelope-b7.envelope.json"
  printf '%s\n' "$SENSOR_HARD_LINE" > "$HOME_DIR/state/envelope-b7.status"
  out=$(run_rollover run envelope-b7)
  expect_code 0 $? "rollover should succeed: $out"
  assert_grep 'Restate its goal' "$HOME_DIR/data/envelope-b7/successor-brief.md" \
    "an existing envelope must make the successor restate before acting"
  assert_no_grep 'No envelope was found' "$HOME_DIR/data/envelope-b7/successor-brief.md" \
    "an existing envelope must not be reported as absent"
  pass "the successor brief tells the successor to restate when an envelope exists"
}

# The actuator's offer line carries the same key through a different wording.
test_rollover_runs_on_the_actuator_offer_line() {
  local out status
  make_case offer offer-b5
  seed_predecessor offer-b5
  printf '%s\n' "$ACTUATOR_OFFERED_LINE" > "$HOME_DIR/state/offer-b5.status"
  out=$(run_rollover run offer-b5)
  status=$?
  expect_code 0 "$status" "the actuator's offer must be actionable too: $out"
  assert_grep 'state=succeeded' "$HOME_DIR/state/offer-b5.rollover" "offer-driven rollover did not succeed"
  pass "run also clears the handoff actuator's offered event, which shares the key"
}

# A rollover that retires the session and then fails to launch must say so, not
# leave the task silently held by nobody.
test_partial_rollover_is_reported() {
  local out status
  make_case partial partial-b6
  seed_predecessor partial-b6
  printf '%s\n' "$SENSOR_HARD_LINE" > "$HOME_DIR/state/partial-b6.status"
  # The predecessor is retired, then the successor's pane never reaches the
  # preserved copy, so the launch refuses. That is the failure mode this path
  # must never hide: the task would otherwise be held by nobody.
  PANE_PATH=$OTHER_WT_DIR
  SETTLE_POLLS=2
  out=$(run_rollover run partial-b6)
  status=$?
  expect_code 1 "$status" "a failed successor launch must fail loudly"
  assert_contains "$out" "successor" "the failure did not name the successor"
  assert_grep 'state=spawn-failed' "$HOME_DIR/state/partial-b6.rollover" \
    "the durable record does not show the partial rollover"
  assert_grep 'blocked [key=context-rollover]: rollover' "$HOME_DIR/state/partial-b6.status" \
    "a partial rollover must reopen the decision, not close it"
  assert_no_grep 'resolved [key=context-rollover]' "$HOME_DIR/state/partial-b6.status" \
    "a partial rollover must never be recorded as resolved"
  pass "a rollover that retires the session but cannot start a successor is reported as blocked"
}

# --- fm-rollover.sh status and audit ----------------------------------------

test_status_distinguishes_open_from_none() {
  local out status
  make_case status status-c1
  seed_predecessor status-c1
  out=$(run_rollover status status-c1)
  status=$?
  expect_code 3 "$status" "no open rollover should report exit 3"
  assert_contains "$out" "rollover=none" "status did not report the absent rollover"

  printf '%s\n' "$SENSOR_HARD_LINE" > "$HOME_DIR/state/status-c1.status"
  out=$(run_rollover status status-c1)
  status=$?
  expect_code 0 "$status" "an open rollover should report exit 0"
  assert_contains "$out" "rollover=open" "status did not report the open rollover"
  assert_contains "$out" "worktree=$WT_DIR" "status did not report the preserved copy"
  pass "status separates an open rollover from a task with none"
}

test_audit_reports_a_stalled_rollover_and_stays_quiet_otherwise() {
  local out status
  make_case audit audit-c2
  seed_predecessor audit-c2
  out=$(run_rollover audit --max-age-seconds 0)
  status=$?
  expect_code 0 "$status" "a fleet with no open rollover must audit clean"
  [ -z "$out" ] || fail "audit must print nothing when every rollover is accounted for: $out"

  printf '%s\n' "$SENSOR_HARD_LINE" > "$HOME_DIR/state/audit-c2.status"
  out=$(run_rollover audit --max-age-seconds 0)
  status=$?
  expect_code 1 "$status" "an open, unfinished rollover must audit non-zero"
  assert_contains "$out" "ROLLOVER_STALLED: audit-c2" "audit did not name the stalled task"

  # A generous age bound leaves a rollover that only just opened alone.
  out=$(run_rollover audit --max-age-seconds 100000)
  status=$?
  expect_code 0 "$status" "a rollover younger than the bound must not be reported"
  [ -z "$out" ] || fail "audit reported a rollover inside its age bound: $out"

  # Once the successor holds the task, the decision is closed and audit is quiet.
  out=$(run_rollover run audit-c2)
  expect_code 0 $? "rollover run should succeed: $out"
  out=$(run_rollover audit --max-age-seconds 0)
  status=$?
  expect_code 0 "$status" "a completed rollover must audit clean"
  [ -z "$out" ] || fail "audit reported a completed rollover: $out"
  pass "audit reports a stalled rollover once and stays quiet for accounted-for ones"
}

test_adopt_launches_into_the_existing_copy_without_allocating_one
test_adopt_refuses_the_primary_checkout
test_adopt_refuses_a_worktree_of_another_repository
test_adopt_refuses_when_the_pane_never_reaches_the_named_copy
test_brief_override_is_confined_to_the_task_data_directory
test_rollover_refuses_without_an_open_decision
test_rollover_refuses_an_already_resolved_decision
test_rollover_refuses_when_the_preserved_copy_is_gone
test_rollover_retires_the_session_and_succeeds_on_the_same_copy
test_successor_brief_tracks_whether_an_envelope_exists
test_rollover_runs_on_the_actuator_offer_line
test_partial_rollover_is_reported
test_status_distinguishes_open_from_none
test_audit_reports_a_stalled_rollover_and_stays_quiet_otherwise

echo "# all fm-rollover tests passed"
