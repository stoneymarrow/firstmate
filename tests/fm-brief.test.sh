#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# Every scaffold below is a dispatch, so each one needs a dispatch record. One
# valid record, written fresh so it is never stale, keeps the existing cases
# about what they were about; the refusal cases build their own.
VALID_DISPATCH="$TMP_ROOT/dispatch.rec"
{
  printf 'harness=claude\nmodel=opus-5\neffort=high\n'
  printf 'wisdom=no existing pattern fits this decomposition\n'
  printf 'diligence=every migration path has to be traced\n'
  printf 'recorded_at=%s\n' "$(date +%s)"
} > "$VALID_DISPATCH"
export FM_DISPATCH_RECORD="$VALID_DISPATCH"

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

# A brief is the worker's session shape, so a dispatch nobody wrote down, or
# wrote down badly, must not become one. Every case here is a real run of the
# real script.
test_dispatch_record_refusals() {
  local home="$TMP_ROOT/dispatch-refusals" rec="$TMP_ROOT/case.rec" now out status
  mkdir -p "$home/data"
  now=$(date +%s)

  refuse() {
    local label=$1 want=$2 id=$3
    shift 3
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj "$@" 2>&1); status=$?
    expect_code 1 "$status" "fm-brief.sh must refuse $label"
    assert_contains "$out" "$want" "refusing $label did not name the fault"
    [ -e "$home/data/$id/brief.md" ] && fail "fm-brief.sh wrote a brief while refusing $label"
    return 0
  }

  out=$(env -u FM_DISPATCH_RECORD FM_HOME="$home" "$ROOT/bin/fm-brief.sh" d-none some-proj 2>&1); status=$?
  expect_code 1 "$status" "fm-brief.sh must refuse a scaffold with no dispatch record"
  assert_contains "$out" "no dispatch record" "refusing an absent record did not say so"

  refuse "an unreadable record" "missing or unreadable" d-gone --dispatch "$TMP_ROOT/not-here.rec"

  printf 'harness=claude\nmodel=opus-5\neffort=high\nwisdom=w\ndiligence=d\n' > "$rec"
  refuse "a record missing recorded_at" "missing recorded_at" d-miss --dispatch "$rec"

  printf 'harness=claude\nmodel=opus-5\neffort=\nwisdom=w\ndiligence=d\nrecorded_at=%s\n' "$now" > "$rec"
  refuse "a record with an empty field" "missing effort" d-empty --dispatch "$rec"

  printf 'harness claude\n' > "$rec"
  refuse "a line that is not key=value" "malformed, not key=value" d-line --dispatch "$rec"

  printf 'harness=claude\nmodel=opus-5\neffort=high\nwisdom=w\ndiligence=d\nrecorded_at=soon\n' > "$rec"
  refuse "a non-numeric recorded_at" "malformed recorded_at" d-ts --dispatch "$rec"

  printf 'harness=claude\nmodel=opus-5\neffort=high\nwisdom=w\ndiligence=d\nrecorded_at=%s\nseat=worker\n' "$now" > "$rec"
  refuse "an unknown field" "unknown field: seat" d-unknown --dispatch "$rec"

  printf 'harness=claude\nmodel=opus-5\neffort=high\nwisdom=w\ndiligence=d\nrecorded_at=%s\nmodel=other\n' "$now" > "$rec"
  refuse "a repeated field" "repeats the field: model" d-dup --dispatch "$rec"

  printf 'harness=claude\nmodel=opus-5\neffort=high\nwisdom=w\ndiligence=d\nrecorded_at=%s\n' "$((now - 7200))" > "$rec"
  refuse "a record decided two hours ago" "is stale" d-stale --dispatch "$rec"

  printf 'harness=claude\nmodel=opus-5\neffort=high\nwisdom=w\ndiligence=d\nrecorded_at=%s\n' "$((now + 9000))" > "$rec"
  refuse "a record dated in the future" "dated in the future" d-future --dispatch "$rec"

  printf 'harness=claude\nmodel=opus-5\neffort=high\nwisdom=same\ndiligence=same\nrecorded_at=%s\n' "$now" > "$rec"
  refuse "one reason standing in for both axes" "separate decisions" d-onereason --dispatch "$rec"

  # The age limit is configurable, and a malformed limit is refused rather than
  # silently treated as no limit at all.
  printf 'harness=claude\nmodel=opus-5\neffort=high\nwisdom=w\ndiligence=d\nrecorded_at=%s\n' "$((now - 60))" > "$rec"
  out=$(FM_DISPATCH_MAX_AGE=10 FM_HOME="$home" "$ROOT/bin/fm-brief.sh" d-age some-proj --dispatch "$rec" 2>&1); status=$?
  expect_code 1 "$status" "fm-brief.sh must honour a tightened FM_DISPATCH_MAX_AGE"
  out=$(FM_DISPATCH_MAX_AGE=oops FM_HOME="$home" "$ROOT/bin/fm-brief.sh" d-badage some-proj --dispatch "$rec" 2>&1); status=$?
  expect_code 1 "$status" "fm-brief.sh must refuse a malformed FM_DISPATCH_MAX_AGE"
  assert_contains "$out" "FM_DISPATCH_MAX_AGE is malformed" "a malformed age limit was not named"

  pass "fm-brief.sh: a missing, stale or malformed dispatch record refuses the scaffold and names the fault"
}

# The accepted dispatch and the session-shape rules have to reach the worker,
# in every generated variant. A worker inherits its shape from its brief.
test_every_brief_carries_dispatch_and_delegation_shape() {
  local home="$TMP_ROOT/shape" brief
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" s-ship some-proj >/dev/null 2>&1 \
    || fail "ship scaffold with a valid dispatch record exited non-zero"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" s-scout some-proj --scout >/dev/null 2>&1 \
    || fail "scout scaffold with a valid dispatch record exited non-zero"
  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" s-sm --secondmate alpha >/dev/null 2>&1 \
    || fail "secondmate scaffold with a valid dispatch record exited non-zero"

  for brief in "$home/data/s-ship/brief.md" "$home/data/s-scout/brief.md" "$home/data/s-sm/brief.md"; do
    assert_present "$brief" "scaffold did not write $brief"
    assert_grep "model opus-5, at high effort" "$brief" "$brief lost the dispatch it was made under"
    assert_grep "Model capability was chosen because" "$brief" "$brief did not state the wisdom reason"
    assert_grep "Reasoning effort was chosen because" "$brief" "$brief did not state the diligence reason"
    assert_grep "Delegation shape" "$brief" "$brief carries no session-shape contract"
    assert_grep "Decompose first" "$brief" "$brief does not require decomposition"
    assert_grep "8 KB" "$brief" "$brief does not set the delegated-read threshold"
    assert_grep "screenshot" "$brief" "$brief does not delegate screenshots"
    assert_grep "fan several readers out" "$brief" "$brief does not require exploration fan-out"
    assert_grep "Never poll and never re-arm" "$brief" "$brief does not ban polling and re-arm loops"
    assert_grep "check cap and a growing interval" "$brief" "$brief gives no lawful no-channel fallback"
    assert_grep "Keep startup lean" "$brief" "$brief does not require startup hygiene"
  done
  pass "fm-brief.sh: every generated brief carries its dispatch and the session-shape contract"
}

# --- workflow shape ---------------------------------------------------------
#
# The failure this guards against is a brief that tells a crewmate to "use a
# workflow" and leaves the shape to it. --workflow either carries a concrete
# shape or refuses to scaffold.

wf_env() {
  FM_WORKFLOW_PHASES='1. survey - list the candidate files
2. audit - one finding list per file
3. report - one merged table' \
  FM_WORKFLOW_FANOUT='phase 2, one agent per candidate file' \
  FM_WORKFLOW_VERIFY='every finding must cite file:line and be rechecked against the file' \
  FM_WORKFLOW_SYNTHESIS='phase 3 merges the verified lists into one table by severity' \
  "$@"
}

test_workflow_refuses_a_shapeless_brief() {
  local home="$TMP_ROOT/wf-blank" out rc
  mkdir -p "$home/data"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" wf1 someproj --workflow 2>&1); rc=$?
  expect_code 1 "$rc" "--workflow with no shape must refuse the scaffold"
  assert_contains "$out" "needs a concrete shape" "the refusal must name the missing shape"
  [ -e "$home/data/wf1/brief.md" ] && fail "a refused --workflow scaffold must write no brief"
  pass "fm-brief: --workflow refuses a brief with no shape"
}

test_workflow_refuses_a_placeholder_shape() {
  local home="$TMP_ROOT/wf-ph" out rc
  mkdir -p "$home/data"
  out=$(FM_WORKFLOW_PHASES='{phases}' FM_WORKFLOW_FANOUT=a FM_WORKFLOW_VERIFY=b FM_WORKFLOW_SYNTHESIS=c \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" wf2 someproj --workflow 2>&1); rc=$?
  expect_code 1 "$rc" "an unreplaced placeholder is not a shape"
  assert_contains "$out" "placeholder" "the refusal must name the placeholder field"
  pass "fm-brief: --workflow refuses an unreplaced placeholder shape"
}

test_workflow_writes_the_whole_shape_into_the_brief() {
  local home="$TMP_ROOT/wf-ok" brief out
  mkdir -p "$home/data"
  out=$(wf_env env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" wf3 someproj --workflow 2>&1)
  assert_contains "$out" "workflow shape attached" "the scaffold must report that a shape was attached"
  brief="$home/data/wf3/brief.md"
  assert_grep "Workflow - REQUIRED SHAPE" "$brief" "the brief must carry the workflow contract"
  assert_grep "one agent per candidate file" "$brief" "the brief must carry the fan-out"
  assert_grep "cite file:line" "$brief" "the brief must carry the verification"
  assert_grep "merges the verified lists" "$brief" "the brief must carry the synthesis"
  assert_grep "audit - one finding list per file" "$brief" "the brief must carry every phase line"
  assert_grep "cannot be built as written" "$brief" "the brief must route a shape that does not fit back to firstmate"
  pass "fm-brief: --workflow writes the decision and the whole shape into the brief"
}

test_workflow_shape_reaches_scout_briefs_too() {
  local home="$TMP_ROOT/wf-scout"
  mkdir -p "$home/data"
  wf_env env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" wf4 someproj --scout --workflow >/dev/null 2>&1 ||
    fail "a scout brief must accept --workflow"
  assert_grep "Workflow - REQUIRED SHAPE" "$home/data/wf4/brief.md" "a scout brief must carry the workflow contract"
  pass "fm-brief: a scout brief carries the workflow shape"
}

test_brief_without_workflow_carries_no_workflow_section() {
  local home="$TMP_ROOT/wf-none"
  mkdir -p "$home/data"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" wf5 someproj >/dev/null 2>&1 || fail "an ordinary ship brief must still scaffold"
  grep -q "Workflow - REQUIRED SHAPE" "$home/data/wf5/brief.md" &&
    fail "a brief firstmate did not mark as needing a workflow must carry no workflow contract"
  pass "fm-brief: an ordinary brief carries no workflow contract"
}

test_workflow_is_refused_on_a_secondmate_charter() {
  local home="$TMP_ROOT/wf-2m" rc
  mkdir -p "$home/data"
  wf_env env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" wf6 --secondmate --no-projects --workflow >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a persistent charter is not a task and takes no workflow shape"
  pass "fm-brief: --workflow is refused on a secondmate charter"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
test_dispatch_record_refusals
test_every_brief_carries_dispatch_and_delegation_shape
test_workflow_refuses_a_shapeless_brief
test_workflow_refuses_a_placeholder_shape
test_workflow_writes_the_whole_shape_into_the_brief
test_workflow_shape_reaches_scout_briefs_too
test_brief_without_workflow_carries_no_workflow_section
test_workflow_is_refused_on_a_secondmate_charter
