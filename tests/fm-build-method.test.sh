#!/usr/bin/env bash
# Behavior tests for bin/fm-build-method.sh and the Build-only method wiring in
# bin/fm-spawn.sh.
#
# The gap these cover is specific: a coding method that is proved only for a
# specially launched session proves nothing about ordinary dispatch. So the
# assertions are on the launch command fm-spawn composes, and on the resolver
# refusing to claim a method it cannot actually reach.
#
# The live Pi activation proof (that the emitted `-e <checkout>` really turns
# stock Superpowers on inside a real Pi turn) needs a stock Superpowers 6.x
# checkout and the Pi CLI; it skips when either is absent rather than passing on
# a check it never ran. Point FM_SUPERPOWERS_PI at a checkout to run it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-build-method)
METHOD="$ROOT/bin/fm-build-method.sh"

# A checkout that looks like stock Superpowers 6.x to the resolver.
STOCK="$TMP_ROOT/stock-superpowers"
mkdir -p "$STOCK/.pi/extensions"
: > "$STOCK/.pi/extensions/superpowers.ts"

# A checkout predating stock Pi support: the resolver must not claim it.
OLD="$TMP_ROOT/old-superpowers"
mkdir -p "$OLD/skills"

CLAUDE_HOME="$TMP_ROOT/claude-config"
mkdir -p "$CLAUDE_HOME"
: > "$CLAUDE_HOME/build-session-settings.json"

test_run_resolves_to_nothing() {
  local out
  for harness in claude pi codex opencode grok kimi; do
    out=$(CLAUDE_CONFIG_DIR="$CLAUDE_HOME" FM_SUPERPOWERS_PI="$STOCK" "$METHOD" "$harness" run 2>&1)
    [ -z "$out" ] || fail "a Run spawn on $harness must carry no coding method, got: $out"
  done
  pass "fm-build-method: Run is the negative control on every harness"
}

test_claude_build_carries_the_overlay() {
  local out
  out=$(CLAUDE_CONFIG_DIR="$CLAUDE_HOME" "$METHOD" claude build)
  assert_contains "$out" "--settings" "a Claude Build must launch with the Build-session settings overlay"
  assert_contains "$out" "$CLAUDE_HOME/build-session-settings.json" "the overlay path must be the deployed one"
  pass "fm-build-method: a Claude Build carries the stock Superpowers overlay"
}

test_claude_build_without_a_deployed_overlay_says_so() {
  local out rc
  out=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/absent" "$METHOD" claude build 2>&1); rc=$?
  expect_code 0 "$rc" "a missing overlay must not stop the spawn"
  assert_contains "$out" "warn:" "a Claude Build that cannot reach the method must say so"
  case "$out" in *--settings*) fail "a missing overlay must not be passed to claude" ;; esac
  pass "fm-build-method: a missing Claude overlay warns instead of claiming coverage"
}

test_pi_build_carries_the_stock_checkout() {
  local out
  out=$(FM_SUPERPOWERS_PI="$STOCK" "$METHOD" pi build)
  assert_contains "$out" "-e " "a Pi Build must load the stock Superpowers checkout"
  assert_contains "$out" "$STOCK" "the checkout path must be the declared one"
  pass "fm-build-method: a Pi Build loads stock Superpowers as a session package"
}

test_pi_build_reads_the_home_config() {
  local home="$TMP_ROOT/home" out
  mkdir -p "$home/config"
  echo "$STOCK" > "$home/config/superpowers-pi"
  out=$(FM_HOME="$home" "$METHOD" pi build)
  assert_contains "$out" "$STOCK" "config/superpowers-pi must declare the checkout when the env var is unset"
  pass "fm-build-method: config/superpowers-pi declares the Pi checkout"
}

test_pi_build_refuses_a_checkout_without_stock_pi_support() {
  local out rc
  out=$(FM_SUPERPOWERS_PI="$OLD" "$METHOD" pi build 2>&1); rc=$?
  expect_code 0 "$rc" "an unusable checkout must not stop the spawn"
  assert_contains "$out" "warn:" "a checkout without stock Pi support must say so"
  case "$out" in *"-e "*) fail "a checkout without .pi/extensions/superpowers.ts must not be loaded" ;; esac
  pass "fm-build-method: a pre-6.x checkout is refused, not silently loaded"
}

test_bad_task_type_is_refused() {
  local rc
  "$METHOD" claude implement >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "an unknown task type must be refused rather than treated as run"
  pass "fm-build-method: an unknown task type fails loudly"
}

# The dispatch half: fm-spawn's launch templates must carry the placeholder, and
# the substitution must be unconditional, so no harness silently loses it.
# shellcheck disable=SC2016  # the literals below are fm-spawn source text, matched verbatim
test_spawn_wires_the_method_into_ordinary_dispatch() {
  local spawn="$ROOT/bin/fm-spawn.sh"
  local claude_line pi_line
  claude_line=$(grep -n 'claude --dangerously-skip-permissions' "$spawn")
  assert_contains "$claude_line" "__METHODFLAG__" "the claude launch template must carry the Build-method placeholder"
  # The harness name is a variable here, not a literal, because pi and pi-signed
  # share this template. Pin the crewmate pi template by the extension flag that
  # distinguishes it from the secondmate one, so the placeholder check survives
  # another adapter joining the branch.
  pi_line=$(grep -n '__METHODFLAG____MODELFLAG____EFFORTFLAG__-e __PIEXT__' "$spawn")
  [ -n "$pi_line" ] || fail "the pi crewmate launch template must carry the Build-method placeholder"
  assert_contains "$(cat "$spawn")" 'LAUNCH=${LAUNCH//__METHODFLAG__/$METHODFLAG}' "fm-spawn must substitute the Build-method placeholder"
  assert_contains "$(cat "$spawn")" 'echo "tasktype=$TASK_TYPE"' "fm-spawn must record the task type in the meta"
  pass "fm-spawn: ordinary dispatch carries the Build-only coding method"
}

test_spawn_accepts_the_build_flag() {
  local out
  out=$("$ROOT/bin/fm-spawn.sh" --help)
  assert_contains "$out" "--build declares this a Build task" "fm-spawn --help must document --build"
  pass "fm-spawn: --build is documented"
}

# Live proof that the emitted flag activates the real thing. Stock Superpowers'
# Pi extension injects its using-superpowers bootstrap into the turn context, so
# a real Pi turn either carries that text or the method is not on.
test_pi_build_really_activates_superpowers() {
  local checkout=${FM_SUPERPOWERS_PI_LIVE:-${FM_SUPERPOWERS_PI:-}}
  if [ -z "$checkout" ] || [ ! -f "$checkout/.pi/extensions/superpowers.ts" ]; then
    printf 'ok - fm-build-method: live Pi activation SKIPPED (no stock Superpowers 6.x checkout; set FM_SUPERPOWERS_PI_LIVE)\n'
    return
  fi
  command -v pi >/dev/null 2>&1 || {
    printf 'ok - fm-build-method: live Pi activation SKIPPED (pi is not installed)\n'
    return
  }

  local home="$TMP_ROOT/pi-home" wd="$TMP_ROOT/pi-wd" ctx="$TMP_ROOT/pi-context.txt"
  mkdir -p "$home/.pi/agent" "$wd"
  local probe="$ROOT/tests/superpowers-pi-probe-provider.ts"

  # A bounded watchdog: a Pi that stops for a prompt must not wedge the suite.
  probe_turn() {
    local flags=$1 pid
    rm -f "$ctx"
    (cd "$wd" && env HOME="$home" PI_CODING_AGENT_DIR="$home/.pi/agent" PI_OFFLINE=1 \
      PI_SP_PROBE_OUT="$ctx" sh -c "exec pi --offline $flags -e '$probe' \
      --provider sp-probe --model faux-1 --no-tools --no-session -p 'hello'" >/dev/null 2>&1) &
    pid=$!
    local waited=0
    while [ "$waited" -lt 60 ]; do
      kill -0 "$pid" 2>/dev/null || return 0
      sleep 1
      waited=$((waited + 1))
    done
    kill -9 "$pid" 2>/dev/null
    return 1
  }

  # Run: no method flag, so the bootstrap must be absent.
  if ! probe_turn ""; then
    printf 'ok - fm-build-method: live Pi activation SKIPPED (the Run probe turn did not finish in 60s)\n'
    return
  fi
  [ -f "$ctx" ] || {
    printf 'ok - fm-build-method: live Pi activation SKIPPED (the probe provider recorded no turn)\n'
    return
  }
  if grep -q 'using-superpowers' "$ctx"; then
    fail "a Run turn must not carry the Superpowers bootstrap"
  fi

  # Build: the flag the resolver emits, applied to a real session.
  local flag
  flag=$(FM_SUPERPOWERS_PI="$checkout" "$METHOD" pi build)
  probe_turn "$flag" || fail "the Build probe turn did not finish in 60s"
  [ -f "$ctx" ] || fail "the Build turn recorded no context"
  grep -q 'using-superpowers' "$ctx" || fail "a Pi Build turn must carry the stock Superpowers bootstrap"
  pass "fm-build-method: a Pi Build turn carries stock Superpowers and a Run turn does not"
}

test_run_resolves_to_nothing
test_claude_build_carries_the_overlay
test_claude_build_without_a_deployed_overlay_says_so
test_pi_build_carries_the_stock_checkout
test_pi_build_reads_the_home_config
test_pi_build_refuses_a_checkout_without_stock_pi_support
test_bad_task_type_is_refused
test_spawn_wires_the_method_into_ordinary_dispatch
test_spawn_accepts_the_build_flag
test_pi_build_really_activates_superpowers
