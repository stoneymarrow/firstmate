#!/usr/bin/env bash
# Focused unit coverage for Herdr readable labels and metadata-owned recovery.
# This entrypoint sources only the Herdr adapter and uses a Herdr-only fake.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-labels.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() {
  case "$1" in *"$2"*) : ;; *) fail "$3" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "$3" ;; *) : ;; esac
}

make_fake_herdr() {  # <fixture-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/responses"
  cat > "$dir/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s' "${1:-}" >> "$FM_HERDR_LOG"
shift || true
for arg in "$@"; do printf '\037%s' "$arg" >> "$FM_HERDR_LOG"; done
printf '\n' >> "$FM_HERDR_LOG"
count_file="$FM_HERDR_RESPONSES/.count"
count=0
[ ! -f "$count_file" ] || IFS= read -r count < "$count_file"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
status=0
[ ! -f "$FM_HERDR_RESPONSES/$count.exit" ] || IFS= read -r status < "$FM_HERDR_RESPONSES/$count.exit"
if [ -f "$FM_HERDR_RESPONSES/$count.out" ]; then
  while IFS= read -r line || [ -n "$line" ]; do printf '%s\n' "$line"; done < "$FM_HERDR_RESPONSES/$count.out"
fi
exit "$status"
SH
  chmod +x "$dir/bin/herdr"
  printf '%s' "$dir/bin"
}

response() {  # <dir> <call> <json>
  printf '%s\n' "$3" > "$1/responses/$2.out"
}
metadata() {  # <path> <kind> <project> <workspace> <tab> <pane>
  printf '%s\n' \
    'backend=herdr' "kind=$2" "project=$3" 'herdr_session=fmtest' \
    "herdr_workspace_id=$4" "herdr_tab_id=$5" "herdr_pane_id=$6" > "$1"
}
run_adapter() {  # <home> <fake-bin> <log> <command> [args...]
  local home=$1 fake=$2 log=$3 command=$4
  shift 4
  PATH="$fake:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" \
    FM_HERDR_RESPONSES="${fake%/bin}/responses" \
    bash -c '. "$0/bin/backends/herdr.sh"; "$1" "${@:2}"' "$ROOT" "$command" "$@"
}

# Labels come from concise semantic subjects; routing ids never format them.
test_strict_adapter_owned_labels() {
  local home out subject
  home="$TMP_ROOT/labels"; mkdir -p "$home"
  out=$(FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label /srv/payments' "$ROOT")
  [ "$out" = 'payments · project' ] || fail "project workspace label mismatch: $out"
  out=$(FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_task_label invoice-check ship' "$ROOT")
  [ "$out" = 'invoice-check · worker' ] || fail "worker label mismatch: $out"
  printf 'research\n' > "$home/.fm-secondmate-home"
  out=$(FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label /srv/ignored' "$ROOT")
  [ "$out" = 'research · second mate' ] || fail "second-mate workspace label mismatch: $out"
  out=$(FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_task_label machine-route secondmate' "$ROOT")
  [ "$out" = 'research · second mate' ] || fail "second-mate task label exposed its route: $out"
  for subject in fm-invoice-check 2ndmate-research firstmate 'bad · worker' 'has space'; do
    if bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_format_label "$1" worker' "$ROOT" "$subject" >/dev/null 2>&1; then
      fail "strict formatter accepted '$subject'"
    fi
  done
  pass "Herdr labels: adapter-owned subject and role formatting is strict"
}

# One malformed Herdr record makes the whole home unusable for discovery.
test_malformed_metadata_refuses() {
  local home meta out status
  home="$TMP_ROOT/malformed"; mkdir -p "$home/state"; meta="$home/state/bad.meta"
  metadata "$meta" ship /srv/payments w1 w1:t1 w1:p1
  printf 'herdr_session=fmtest\n' >> "$meta"
  out=$(FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_metadata_validate_home "$1/state"' "$ROOT" "$home" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate Herdr identity metadata was accepted"
  assert_contains "$out" 'malformed herdr metadata' "malformed metadata refusal was not explained"
  pass "Herdr metadata: duplicate exact identity fields refuse"
}

# The prior project-primary spelling is valid only on one exact metadata tuple.
# A native same-label tuple does not block exact migration and is never touched.
test_prior_project_label_requires_exact_metadata() {
  local dir home meta log fake out calls
  dir="$TMP_ROOT/prior-project-exact"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"
  metadata "$meta" ship /srv/payments old old:t1 old:p1
  printf '%s\n' \
    'herdr_workspace_label=payments · primary' \
    'herdr_tab_label=invoice-check · worker' \
    'herdr_pane_label=invoice-check · worker' >> "$meta"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"native","label":"payments · primary"},{"workspace_id":"old","label":"payments · primary"}]}}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"old","tab_id":"old:t1","label":"invoice-check · worker"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"workspace_id":"old","tab_id":"old:t1","pane_id":"old:p1"}]}}'
  response "$dir" 4 '{"result":{"pane":{"workspace_id":"old","tab_id":"old:t1","pane_id":"old:p1","label":"invoice-check · worker"}}}'
  response "$dir" 5 '{"result":{"workspace":{"workspace_id":"old","label":"payments · project"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
    fmtest /srv/payments "$meta") || fail "exact prior project metadata could not migrate: $out"
  [ "$out" = old ] || fail "exact prior project migration returned '$out'"
  calls=$(cat "$log")
  assert_contains "$calls" $'workspace\037rename\037old\037payments · project' \
    "exact prior project workspace was not migrated"
  assert_not_contains "$calls" $'workspace\037rename\037native' \
    "prior project migration touched the native same-label tuple"
  pass "Herdr discovery: prior project label requires exact metadata"
}

# The old primary-home `firstmate` project label may migrate only when the
# complete ambient native tuple proves a different workspace in the same
# physical named session.
test_legacy_firstmate_workspace_requires_proved_native_separation() {
  local dir home meta log fake socket out calls
  dir="$TMP_ROOT/legacy-firstmate-separated"; home="$dir/home"
  mkdir -p "$home/state" "$dir/session"
  meta="$home/state/invoice-check.meta"
  metadata "$meta" ship /srv/firstmate old old:t1 old:p1
  printf '%s\n' \
    'herdr_workspace_label=firstmate' \
    'herdr_tab_label=invoice-check · worker' \
    'herdr_pane_label=invoice-check · worker' >> "$meta"
  socket="$dir/session/herdr.sock"; : > "$socket"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"native","label":"firstmate · primary"},{"workspace_id":"old","label":"firstmate"}]}}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"old","tab_id":"old:t1","label":"invoice-check · worker"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"workspace_id":"old","tab_id":"old:t1","pane_id":"old:p1"}]}}'
  response "$dir" 4 '{"result":{"pane":{"workspace_id":"old","tab_id":"old:t1","pane_id":"old:p1","label":"invoice-check · worker"}}}'
  response "$dir" 5 "{\"sessions\":[{\"name\":\"fmtest\",\"running\":true,\"socket_path\":\"$socket\"}]}"
  response "$dir" 6 '{"result":{"workspaces":[{"workspace_id":"native","label":"firstmate · primary"},{"workspace_id":"old","label":"firstmate"}]}}'
  response "$dir" 7 '{"result":{"tabs":[{"workspace_id":"native","tab_id":"native:t1","label":"firstmate · primary"}]}}'
  response "$dir" 8 '{"result":{"panes":[{"workspace_id":"native","tab_id":"native:t1","pane_id":"native:p1","label":"firstmate · primary"}]}}'
  response "$dir" 9 '{"result":{"pane":{"workspace_id":"native","tab_id":"native:t1","pane_id":"native:p1","label":"firstmate · primary"}}}'
  response "$dir" 10 '{"result":{"workspace":{"workspace_id":"old","label":"firstmate · project"}}}'
  out=$(PATH="$fake:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" \
    FM_HERDR_RESPONSES="$dir/responses" HERDR_ENV=1 HERDR_SOCKET_PATH="$socket" \
    HERDR_WORKSPACE_ID=native HERDR_TAB_ID=native:t1 HERDR_PANE_ID=native:p1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_ensure fmtest /srv/firstmate "$1"' \
      "$ROOT" "$meta") || fail "proved non-native legacy project workspace could not migrate"
  [ "$out" = old ] || fail "proved non-native legacy migration returned '$out'"
  calls=$(<"$log")
  assert_contains "$calls" $'workspace\037rename\037old\037firstmate · project' \
    "proved non-native legacy workspace was not migrated"
  assert_not_contains "$calls" $'workspace\037rename\037native' \
    "proved non-native migration touched the native workspace"
  pass "Herdr discovery: legacy firstmate workspace migrates only after proved native separation"
}

# The ambient native helper proves the complete live relationship and keeps
# caller-owned live-tuple globals untouched. Cross-parent and unreadable shapes
# return no workspace authority even when every environment string is valid.
test_native_workspace_requires_exact_live_tuple() {
  local mode dir home log fake socket out status
  for mode in exact wrong-tab-parent wrong-pane-parent unreadable; do
    dir="$TMP_ROOT/native-live-$mode"; home="$dir/home"; mkdir -p "$home/state" "$dir/session"
    socket="$dir/session/herdr.sock"; : > "$socket"
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    response "$dir" 1 "{\"sessions\":[{\"name\":\"fmtest\",\"running\":true,\"socket_path\":\"$socket\"}]}"
    if [ "$mode" = unreadable ]; then
      response "$dir" 2 'not-json'
    else
      response "$dir" 2 '{"result":{"workspaces":[{"workspace_id":"native","label":"firstmate · primary"}]}}'
      if [ "$mode" = wrong-tab-parent ]; then
        response "$dir" 3 '{"result":{"tabs":[{"workspace_id":"foreign","tab_id":"native:t1","label":"firstmate · primary"}]}}'
      else
        response "$dir" 3 '{"result":{"tabs":[{"workspace_id":"native","tab_id":"native:t1","label":"firstmate · primary"}]}}'
        if [ "$mode" = wrong-pane-parent ]; then
          response "$dir" 4 '{"result":{"panes":[{"workspace_id":"native","tab_id":"foreign:t1","pane_id":"native:p1","label":"firstmate · primary"}]}}'
        else
          response "$dir" 4 '{"result":{"panes":[{"workspace_id":"native","tab_id":"native:t1","pane_id":"native:p1","label":"firstmate · primary"}]}}'
          response "$dir" 5 '{"result":{"pane":{"workspace_id":"native","tab_id":"native:t1","pane_id":"native:p1","label":"firstmate · primary"}}}'
        fi
      fi
    fi
    out=$(PATH="$fake:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" \
      FM_HERDR_RESPONSES="$dir/responses" HERDR_ENV=1 HERDR_SOCKET_PATH="$socket" \
      HERDR_WORKSPACE_ID=native HERDR_TAB_ID=native:t1 HERDR_PANE_ID=native:p1 \
      FM_TEST_OUTPUT="$dir/native.out" bash -c '
        . "$0/bin/backends/herdr.sh"
        FM_BACKEND_HERDR_LIVE_TUPLE_STATE=caller-state
        FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL=caller-workspace
        FM_BACKEND_HERDR_LIVE_TAB_LABEL=caller-tab
        FM_BACKEND_HERDR_LIVE_PANE_LABEL=caller-pane
        if fm_backend_herdr_native_workspace_for_session fmtest > "$FM_TEST_OUTPUT"; then
          rc=0
        else
          rc=$?
        fi
        printf "%s|%s|%s|%s|%s" "$rc" "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" \
          "$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL" "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" \
          "$FM_BACKEND_HERDR_LIVE_PANE_LABEL"
      ' "$ROOT")
    status=${out%%|*}
    [ "$out" = "$status|caller-state|caller-workspace|caller-tab|caller-pane" ] \
      || fail "$mode native proof overwrote caller live-tuple globals: $out"
    if [ "$mode" = exact ]; then
      [ "$status" = 0 ] && [ "$(cat "$dir/native.out")" = native ] \
        || fail "exact live native tuple did not return its workspace"
    else
      [ "$status" -ne 0 ] && [ ! -s "$dir/native.out" ] \
        || fail "$mode native tuple shape granted workspace authority"
    fi
  done
  pass "Herdr native proof: exact live tuple is required without caller-global leakage"
}

# A primary workspace is adopted only through its complete metadata tuple;
# a second semantic label candidate makes discovery ambiguous.
test_exact_workspace_discovery_refuses_semantic_duplicate() {
  local dir home meta log fake out status calls
  dir="$TMP_ROOT/workspace-duplicate"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"; metadata "$meta" ship /srv/payments w1 w1:t1 w1:p1
  printf 'herdr_workspace_label=payments · project\n' >> "$meta"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"payments · project"},{"workspace_id":"decoy","label":"payments · project"}]}}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"invoice-check · worker"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}'
  response "$dir" 4 '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure fmtest /srv/payments 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate semantic workspace labels were accepted"
  calls=$(<"$log")
  assert_not_contains "$calls" $'workspace\037rename' "ambiguous discovery renamed a workspace"
  assert_not_contains "$calls" $'workspace\037create' "ambiguous discovery created a workspace"
  pass "Herdr discovery: exact tuple does not authorize a duplicate semantic label"
}

# A marked home without exact child or parent metadata never adopts a
# readable or legacy label collision and never mutates it.
test_marked_workspace_collision_is_untouched() {
  local mode dir home log fake out status calls label
  for mode in readable legacy; do
    dir="$TMP_ROOT/marked-collision-$mode"; home="$dir/home"; mkdir -p "$home/state"
    printf 'research\n' > "$home/.fm-secondmate-home"
    label='research · second mate'; [ "$mode" != legacy ] || label=2ndmate-research
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    response "$dir" 1 "{\"result\":{\"workspaces\":[{\"workspace_id\":\"foreign\",\"label\":\"$label\"}]}}"
    out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure fmtest /srv/research 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "unowned marked $mode collision was adopted"
    calls=$(<"$log")
    assert_not_contains "$calls" $'workspace\037rename' "marked $mode collision was renamed"
    assert_not_contains "$calls" $'workspace\037create' "marked $mode collision triggered a create"
    assert_not_contains "$calls" $'pane\037close' "marked $mode collision triggered cleanup"
  done
  pass "Herdr marked home: unowned readable and legacy collisions refuse without mutation"
}

# Prefix-free list_live walks only complete local records. A marked home's
# parent-looking label is not enough to synthesize a parent route.
test_prefix_free_list_live_uses_only_exact_local_metadata() {
  local dir home meta log fake out
  dir="$TMP_ROOT/list-live"; home="$dir/home"; mkdir -p "$home/state"
  printf 'research\n' > "$home/.fm-secondmate-home"
  meta="$home/state/source-check.meta"; metadata "$meta" ship /srv/research-notes w2 w2:t3 w2:p3
  printf '%s\n' \
    'display_label=source-check · worker' \
    'herdr_workspace_label=research · second mate' \
    'herdr_tab_label=source-check · worker' \
    'herdr_pane_label=source-check · worker' >> "$meta"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w2","label":"research · second mate"}]}}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"w2","tab_id":"w2:t3","label":"source-check · worker"},{"workspace_id":"w2","tab_id":"w2:t2","label":"research · second mate"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"pane_id":"w2:p3","tab_id":"w2:t3"},{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}'
  response "$dir" 4 '{"result":{"pane":{"workspace_id":"w2","tab_id":"w2:t3","pane_id":"w2:p3","label":"source-check · worker"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_list_live fmtest) \
    || fail "exact prefix-free list_live failed"
  [ "$out" = $'fmtest:w2:p3\tsource-check · worker' ] || fail "exact list_live output mismatch: $out"
  assert_not_contains "$out" 'research · second mate' "label-only parent endpoint was inferred"
  pass "Herdr list_live: exact local tuple is prefix-free and no parent is inferred"
}

# Exact projected metadata corroborates its recorded child workspace label.
# Discovery must not replace it with the recomputed parent-project label.
test_projected_list_live_uses_recorded_workspace_label() {
  local dir home meta log fake out token child
  dir="$TMP_ROOT/list-live-projected"; home="$dir/home"; mkdir -p "$home/state"
  token=AbCdEfGhIjKlMnOpQrStUv
  child="└ invoice-check · p:$token"
  meta="$home/state/invoice-check.meta"
  metadata "$meta" ship /srv/payments w2 w2:t2 w2:p2
  printf '%s\n' \
    'display_label=invoice-check · worker' \
    "herdr_workspace_label=$child" \
    'herdr_tab_label=invoice-check · worker' \
    'herdr_pane_label=invoice-check · worker' >> "$meta"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"payments · primary\"},{\"workspace_id\":\"w2\",\"label\":\"$child\"}]}}"
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"w2","tab_id":"w2:t2","label":"invoice-check · worker"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"workspace_id":"w2","pane_id":"w2:p2","tab_id":"w2:t2"}]}}'
  response "$dir" 4 '{"result":{"pane":{"workspace_id":"w2","tab_id":"w2:t2","pane_id":"w2:p2","label":"invoice-check · worker"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_list_live fmtest) \
    || fail "projected exact list_live refused its recorded child label"
  [ "$out" = $'fmtest:w2:p2\tinvoice-check · worker' ] \
    || fail "projected list_live output mismatch: $out"
  pass "Herdr list_live: exact projected child uses its recorded workspace label"
}

# The projected exception does not let an arbitrary exact metadata label
# replace the derived flat-workspace contract.
test_flat_list_live_refuses_arbitrary_recorded_workspace_label() {
  local dir home meta log fake out status
  dir="$TMP_ROOT/list-live-flat-foreign"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"
  metadata "$meta" ship /srv/payments w1 w1:t1 w1:p1
  printf '%s\n' \
    'display_label=invoice-check · worker' \
    'herdr_workspace_label=foreign flat label' \
    'herdr_tab_label=invoice-check · worker' \
    'herdr_pane_label=invoice-check · worker' >> "$meta"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"foreign flat label"}]}}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"invoice-check · worker"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"workspace_id":"w1","pane_id":"w1:p1","tab_id":"w1:t1"}]}}'
  response "$dir" 4 '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","label":"invoice-check · worker"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_list_live fmtest 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "arbitrary flat recorded workspace label was accepted"
  [ -z "$out" ] || fail "arbitrary flat workspace refusal leaked output: $out"
  pass "Herdr list_live: projected exception does not widen flat workspace labels"
}

# A positively absent metadata-owned workspace creates a new workspace from
# the response without touching any old object.
test_missing_workspace_recreates_without_mutation() {
  local dir home meta log fake out calls
  dir="$TMP_ROOT/missing-workspace"; home="$dir/home"; mkdir -p "$home/state"
  printf 'research\n' > "$home/.fm-secondmate-home"
  meta="$home/state/source-check.meta"; metadata "$meta" ship /srv/research-notes old old:t1 old:p1
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[]}}'
  response "$dir" 2 '{"result":{"tabs":[]}}'
  response "$dir" 3 '{"error":{"code":"pane_not_found"}}'
  response "$dir" 4 '{"result":{"workspace":{"workspace_id":"new","label":"research · second mate"},"tab":{"tab_id":"new:t1"},"root_pane":{"pane_id":"new:p1"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure fmtest /srv/research-notes "$meta") \
    || fail "positively absent workspace was not recreated"
  [ "$out" = new ] || fail "missing workspace recreation returned '$out'"
  calls=$(<"$log")
  assert_contains "$calls" $'workspace\037create' "missing workspace did not create a replacement"
  assert_not_contains "$calls" $'workspace\037rename' "missing workspace recovery renamed an object"
  assert_not_contains "$calls" $'pane\037close' "missing workspace recovery closed an object"
  pass "Herdr recovery: positively absent workspace recreates without old-object mutation"
}

# A positively absent exact tab reuses its metadata-owned workspace and creates
# a fresh task without closing anything.
test_missing_tab_reuses_workspace_and_creates_task() {
  local dir home meta log fake out calls
  dir="$TMP_ROOT/missing-tab"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"; metadata "$meta" ship /srv/payments w1 old:t1 old:p1
  printf 'herdr_workspace_label=payments · primary\n' >> "$meta"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"payments · primary"}]}}'
  response "$dir" 2 '{"result":{"tabs":[]}}'
  response "$dir" 3 '{"error":{"code":"pane_not_found"}}'
  response "$dir" 4 '{"result":{"tabs":[]}}'
  response "$dir" 5 '{"result":{"workspaces":[{"workspace_id":"w1","label":"payments · primary"}]}}'
  response "$dir" 6 '{"result":{"tabs":[]}}'
  response "$dir" 7 '{"error":{"code":"pane_not_found"}}'
  response "$dir" 8 '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
  response "$dir" 9 '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t2","label":"invoice-check · worker"}}}'
  response "$dir" 10 '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p2","label":"invoice-check · worker"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_create_task \
    fmtest:w1 invoice-check ship /srv/payments '' "$meta") \
    || fail "positively absent tab did not recreate the task"
  [ "$out" = 'w1:t2 w1:p2' ] || fail "missing tab recovery returned '$out'"
  calls=$(<"$log")
  assert_contains "$calls" $'tab\037create' "missing tab recovery did not create a task"
  assert_not_contains "$calls" $'tab\037close' "missing tab recovery closed an old tab"
  assert_not_contains "$calls" $'pane\037close' "missing tab recovery closed an old pane"
  pass "Herdr recovery: positively absent tab reuses its workspace and creates the task"
}

# A positively absent exact pane also keeps the exact empty tab untouched and
# creates a new task in the metadata-owned workspace.
test_missing_pane_reuses_workspace_without_close() {
  local dir home meta log fake out calls
  dir="$TMP_ROOT/missing-pane"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"; metadata "$meta" ship /srv/payments w1 old:t1 old:p1
  printf '%s\n' 'herdr_workspace_label=payments · primary' \
    'herdr_tab_label=invoice-check · worker' >> "$meta"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"payments · primary"}]}}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"old:t1","label":"invoice-check · worker"}]}}'
  response "$dir" 3 '{"result":{"panes":[]}}'
  response "$dir" 4 '{"error":{"code":"pane_not_found"}}'
  response "$dir" 5 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"old:t1","label":"invoice-check · worker"}]}}'
  response "$dir" 6 '{"result":{"workspaces":[{"workspace_id":"w1","label":"payments · primary"}]}}'
  response "$dir" 7 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"old:t1","label":"invoice-check · worker"}]}}'
  response "$dir" 8 '{"result":{"panes":[]}}'
  response "$dir" 9 '{"error":{"code":"pane_not_found"}}'
  response "$dir" 10 '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
  response "$dir" 11 '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t2","label":"invoice-check · worker"}}}'
  response "$dir" 12 '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p2","label":"invoice-check · worker"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_create_task \
    fmtest:w1 invoice-check ship /srv/payments '' "$meta") \
    || fail "positively absent pane did not recreate the task"
  [ "$out" = 'w1:t2 w1:p2' ] || fail "missing pane recovery returned '$out'"
  calls=$(<"$log")
  assert_not_contains "$calls" $'tab\037close' "missing pane recovery closed the empty old tab"
  assert_not_contains "$calls" $'pane\037close' "missing pane recovery closed an old pane"
  pass "Herdr recovery: positively absent pane recreates without closing the exact empty tab"
}

# Prefix-free discovery keeps healthy exact records while skipping a positively
# absent record from the same home.
test_list_live_keeps_healthy_and_skips_missing() {
  local dir home healthy missing log fake out
  dir="$TMP_ROOT/list-healthy-missing"; home="$dir/home"; mkdir -p "$home/state"
  healthy="$home/state/a-healthy.meta"; metadata "$healthy" ship /srv/payments w1 w1:t1 w1:p1
  printf '%s\n' 'display_label=a-healthy · worker' 'herdr_workspace_label=payments · primary' \
    'herdr_tab_label=a-healthy · worker' 'herdr_pane_label=a-healthy · worker' >> "$healthy"
  missing="$home/state/z-missing.meta"; metadata "$missing" ship /srv/payments gone gone:t1 gone:p1
  printf '%s\n' 'display_label=z-missing · worker' 'herdr_workspace_label=payments · primary' \
    'herdr_tab_label=z-missing · worker' 'herdr_pane_label=z-missing · worker' >> "$missing"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"payments · primary"}]}}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"a-healthy · worker"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}'
  response "$dir" 4 '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","label":"a-healthy · worker"}}}'
  response "$dir" 5 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"a-healthy · worker"}]}}'
  response "$dir" 6 '{"error":{"code":"pane_not_found"}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_list_live fmtest) \
    || fail "healthy-plus-missing list_live refused"
  [ "$out" = $'fmtest:w1:p1\ta-healthy · worker' ] || fail "healthy-plus-missing output mismatch: $out"
  pass "Herdr list_live: healthy exact record survives a positively absent sibling"
}

# Any malformed live response refuses the whole discovery read.
test_list_live_unreadable_refuses() {
  local dir home meta log fake out status
  dir="$TMP_ROOT/list-unreadable"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"; metadata "$meta" ship /srv/payments w1 w1:t1 w1:p1
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"payments · primary"}]}}'
  response "$dir" 2 '{"result":{"tabs":"unreadable"}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_list_live fmtest 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unreadable live record was hidden"
  [ -z "$out" ] || fail "unreadable list_live leaked a partial result: $out"
  pass "Herdr list_live: unreadable live record refuses the whole read"
}

# A semantic duplicate refuses before tab creation, regardless of routing id.
test_duplicate_task_label_refuses() {
  local dir home log fake out status calls
  dir="$TMP_ROOT/task-duplicate"; home="$dir/home"; mkdir -p "$home/state"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"other-route","label":"invoice-check · worker"}]}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_create_task fmtest:w1 invoice-check ship /srv/payments 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate readable task label was accepted"
  calls=$(<"$log")
  assert_not_contains "$calls" $'tab\037create' "duplicate task label created a tab"
  pass "Herdr task labels: duplicate semantics refuse without a routing suffix"
}

write_husk_snapshot() {  # <dir> <first-call> <workspace> <tab> <pane> <tab-label> <pane-label> <cwd> [pane-list] [agent]
  local dir=$1 first=$2 ws=$3 tab=$4 pane=$5 tab_label=$6 pane_label=$7 cwd=$8
  local pane_list=${9:-"[{\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}]"}
  local agent=${10:-'{"error":{"code":"agent_not_found"}}'}
  response "$dir" "$first" "{\"result\":{\"workspaces\":[{\"workspace_id\":\"$ws\",\"label\":\"payments · primary\"}]}}"
  response "$dir" "$((first + 1))" "{\"result\":{\"tabs\":[{\"workspace_id\":\"$ws\",\"tab_id\":\"$tab\",\"label\":\"$tab_label\"}]}}"
  response "$dir" "$((first + 2))" "{\"result\":{\"panes\":$pane_list}}"
  response "$dir" "$((first + 3))" "{\"result\":{\"pane\":{\"workspace_id\":\"$ws\",\"tab_id\":\"$tab\",\"pane_id\":\"$pane\",\"label\":\"$pane_label\",\"cwd\":\"$cwd\"}}}"
  response "$dir" "$((first + 4))" "$agent"
}

# The no-agent husk authority is the whole snapshot, not any one label.
test_husk_snapshot_requires_full_tuple_shape_and_agent_absence() {
  local mode dir home log fake out status pane_list agent
  for mode in exact wrong-parent wrong-cwd wrong-tab-label wrong-pane-label extra-pane live-agent; do
    dir="$TMP_ROOT/snapshot-$mode"; home="$dir/home"; mkdir -p "$home/state"
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    pane_list='[{"pane_id":"w1:p2","tab_id":"w1:t2"}]'
    agent='{"error":{"code":"agent_not_found"}}'
    case "$mode" in
      wrong-parent) write_husk_snapshot "$dir" 1 w9 w1:t2 w1:p2 'invoice-check · worker' 'invoice-check · worker' /srv/payments ;;
      wrong-cwd) write_husk_snapshot "$dir" 1 w1 w1:t2 w1:p2 'invoice-check · worker' 'invoice-check · worker' /srv/other ;;
      wrong-tab-label) write_husk_snapshot "$dir" 1 w1 w1:t2 w1:p2 unexpected 'invoice-check · worker' /srv/payments ;;
      wrong-pane-label) write_husk_snapshot "$dir" 1 w1 w1:t2 w1:p2 'invoice-check · worker' unexpected /srv/payments ;;
      extra-pane)
        pane_list='[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p9","tab_id":"w1:t2"}]'
        write_husk_snapshot "$dir" 1 w1 w1:t2 w1:p2 'invoice-check · worker' 'invoice-check · worker' /srv/payments "$pane_list"
        ;;
      live-agent)
        agent='{"result":{"agent":{"agent_status":"idle"}}}'
        write_husk_snapshot "$dir" 1 w1 w1:t2 w1:p2 'invoice-check · worker' 'invoice-check · worker' /srv/payments "$pane_list" "$agent"
        ;;
      *) write_husk_snapshot "$dir" 1 w1 w1:t2 w1:p2 'invoice-check · worker' 'invoice-check · worker' /srv/payments ;;
    esac
    out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_husk_snapshot_exact \
      fmtest w1 w1:t2 w1:p2 'invoice-check · worker' fm-invoice-check \
      'invoice-check · worker' 'invoice-check · worker' /srv/payments '' 2>&1)
    status=$?
    if [ "$mode" = exact ]; then
      [ "$status" -eq 0 ] && [ -n "$out" ] || fail "exact husk snapshot refused"
    else
      [ "$status" -ne 0 ] || fail "$mode husk snapshot was accepted"
    fi
  done
  pass "Herdr husk snapshot: parent tuple, one-pane shape, labels, cwd, and no-agent state are exact"
}

# Legacy metadata without a pane-label field accepts an empty live pane label,
# while a recorded label stays exact and an unexpected nonempty label refuses.
test_legacy_empty_pane_label_rules() {
  local mode dir home log fake out status recorded pane_label
  for mode in empty-accepted recorded-required unexpected-refused; do
    dir="$TMP_ROOT/legacy-pane-$mode"; home="$dir/home"; mkdir -p "$home/state"
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    recorded=""; pane_label=""
    case "$mode" in
      recorded-required) recorded='invoice-check · worker' ;;
      unexpected-refused) pane_label=unexpected ;;
    esac
    write_husk_snapshot "$dir" 1 w1 w1:t2 w1:p2 'invoice-check · worker' "$pane_label" /srv/payments
    out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_husk_snapshot_exact \
      fmtest w1 w1:t2 w1:p2 'invoice-check · worker' fm-invoice-check \
      'invoice-check · worker' "$recorded" /srv/payments '' 2>&1)
    status=$?
    if [ "$mode" = empty-accepted ]; then
      [ "$status" -eq 0 ] && [ -n "$out" ] || fail "legacy empty pane label was refused"
    else
      [ "$status" -ne 0 ] || fail "$mode pane-label mismatch was accepted"
    fi
  done
  pass "Herdr husk labels: absent legacy pane label permits empty only under semantic rules"
}

# The empty-pane legacy husk is matched twice before its exact old tab closes.
test_legacy_empty_pane_husk_recovers_twice() {
  local dir home meta log fake out calls
  dir="$TMP_ROOT/legacy-empty-recover"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"; metadata "$meta" ship /srv/payments w1 w1:t2 w1:p2
  printf 'herdr_tab_label=fm-invoice-check\n' >> "$meta"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  write_husk_snapshot "$dir" 1 w1 w1:t2 w1:p2 fm-invoice-check '' /srv/payments
  response "$dir" 6 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t2","label":"fm-invoice-check"}]}}'
  response "$dir" 7 '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}'
  response "$dir" 8 '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t3","label":"invoice-check · worker"}}}'
  response "$dir" 9 '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"invoice-check · worker"}}}'
  write_husk_snapshot "$dir" 10 w1 w1:t2 w1:p2 fm-invoice-check '' /srv/payments
  response "$dir" 15 '{}'
  response "$dir" 16 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t3","label":"invoice-check · worker"}]}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_create_task \
    fmtest:w1 invoice-check ship /srv/payments '' "$meta") \
    || fail "legacy empty-pane husk did not recover"
  [ "$out" = 'w1:t3 w1:p3' ] || fail "legacy empty-pane recovery returned '$out'"
  calls=$(<"$log")
  assert_contains "$calls" $'tab\037close\037w1:t2' "exact legacy husk tab was not closed after two matches"
  assert_not_contains "$calls" $'pane\037close\037w1:p2' "legacy recovery closed the old pane directly"
  pass "Herdr husk recovery: legacy empty pane label matches twice before exact replacement"
}

# The old tuple is read twice. A change before close rolls back only the pane
# returned by the new tab-create response.
test_husk_revalidation_rolls_back_only_new_pane() {
  local dir home meta log fake out status calls
  dir="$TMP_ROOT/husk-race"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"; metadata "$meta" ship /srv/payments w1 w1:t2 w1:p2
  printf '%s\n' 'herdr_tab_label=invoice-check · worker' 'herdr_pane_label=invoice-check · worker' >> "$meta"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  write_husk_snapshot "$dir" 1 w1 w1:t2 w1:p2 'invoice-check · worker' 'invoice-check · worker' /srv/payments
  response "$dir" 6 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t2","label":"invoice-check · worker"}]}}'
  response "$dir" 7 '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}'
  response "$dir" 8 '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t3","label":"invoice-check · worker"}}}'
  response "$dir" 9 '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t3","pane_id":"w1:p3","label":"invoice-check · worker"}}}'
  write_husk_snapshot "$dir" 10 w1 w1:t2 w1:p2 'invoice-check · worker' 'invoice-check · worker' /srv/repurposed
  response "$dir" 15 '{}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_create_task \
    fmtest:w1 invoice-check ship /srv/payments '' "$meta" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "changed husk snapshot was accepted"
  calls=$(<"$log")
  assert_contains "$calls" $'pane\037close\037w1:p3' "new response-derived pane was not rolled back"
  assert_not_contains "$calls" $'tab\037close\037w1:t2' "changed old tab was closed"
  pass "Herdr husk recovery: immediate revalidation rolls back only the new pane"
}

# Label verification after creation uses only response-derived objects.
test_new_object_label_failure_rolls_back_only_response_pane() {
  local dir home log fake out status calls
  dir="$TMP_ROOT/new-rollback"; home="$dir/home"; mkdir -p "$home/state"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"tabs":[]}}'
  response "$dir" 2 '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9"}}}'
  response "$dir" 3 '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t9","label":"invoice-check · worker"}}}'
  response "$dir" 4 '{"result":{"pane":{"workspace_id":"wrong","tab_id":"w1:t9","pane_id":"w1:p9","label":"invoice-check · worker"}}}'
  response "$dir" 5 '{}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_create_task fmtest:w1 invoice-check ship /srv/payments 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mismatched response identity was accepted"
  calls=$(<"$log")
  assert_contains "$calls" $'pane\037close\037w1:p9' "new pane was not rolled back"
  assert_not_contains "$calls" $'tab\037close' "rollback closed a tab"
  assert_not_contains "$calls" $'workspace\037close' "rollback closed a workspace"
  pass "Herdr rollback: label failure touches only the response-derived pane"
}

# Version 1 and legacy version 2 stay byte-compatible; fresh exact bindings
# use version 3 with one task-kind field and the adapter-derived label.
test_projection_journal_versions_and_readable_binding() {
  local dir home state journal token label before after out
  dir="$TMP_ROOT/journal-versions"; home="$dir/home"; state="$dir/state"
  mkdir -p "$home" "$state"
  token=AbCdEfGhIjKlMnOpQrStUv
  journal="$state/invoice-check.herdr-presentation"
  {
    printf 'version=2\n'
    printf 'task_id=invoice-check\n'
    printf 'projection_id=%s\n' "$token"
    printf 'home=%s\n' "$home"
    printf 'session=fmtest\nworkspace_id=w2\ntab_id=w2:t2\npane_id=w2:p2\n'
    printf 'parent_workspace_id=w1\nparent_label=payments · primary\n'
    printf 'workspace_label=└ invoice-check · p:%s\n' "$token"
    printf 'task_label=fm-invoice-check\n'
  } > "$journal"
  before=$(shasum -a 256 "$journal")
  out=$(FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_snapshot "$1" invoice-check || exit 1
    printf "%s|%s|%s|%s" "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION" \
      "$FM_BACKEND_HERDR_JOURNAL_VERSION" "$FM_BACKEND_HERDR_JOURNAL_TASK_KIND" \
      "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL"
  ' "$ROOT" "$journal") || fail "legacy version 2 journal was not readable"
  [ "$out" = '2|2||fm-invoice-check' ] || fail "legacy version 2 snapshot changed: $out"
  after=$(shasum -a 256 "$journal")
  [ "$before" = "$after" ] || fail "reading legacy version 2 rewrote it"

  rm -f "$journal"
  out=$(FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    token=$(fm_backend_herdr_projection_journal_create "$1" invoice-check) || exit 1
    label=$(fm_backend_herdr_projection_workspace_label invoice-check "$token")
    home=$(fm_backend_herdr_projection_home_identity "$2") || exit 1
    task_label=$(FM_HOME="$2" fm_backend_herdr_task_label invoice-check ship) || exit 1
    fm_backend_herdr_projection_journal_bind "$1/invoice-check.herdr-presentation" \
      invoice-check ship "$home" fmtest w2 w2:t2 w2:p2 w1 \
      "payments · primary" "$label" "$task_label" || exit 1
    fm_backend_herdr_projection_journal_snapshot "$1/invoice-check.herdr-presentation" invoice-check || exit 1
    printf "%s|%s|%s|%s" "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION" \
      "$FM_BACKEND_HERDR_JOURNAL_VERSION" "$FM_BACKEND_HERDR_JOURNAL_TASK_KIND" \
      "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL"
  ' "$ROOT" "$state" "$home") || fail "fresh version 3 binding failed"
  [ "$out" = '3|2|ship|invoice-check · worker' ] || fail "fresh version 3 snapshot mismatch: $out"
  [ "$(wc -l < "$journal" | tr -d '[:space:]')" = 13 ] || fail "version 3 journal did not add exactly one field"
  [ "$(grep -c '^task_kind=ship$' "$journal")" = 1 ] || fail "version 3 journal task kind was missing or duplicated"
  label=$(grep '^workspace_label=' "$journal" | cut -d= -f2-)
  [ -n "$label" ] || fail "version 3 workspace label was missing"

  cp "$journal" "$dir/bad-kind"
  perl -pi -e 's/^task_kind=ship$/task_kind=secondmate/' "$dir/bad-kind"
  if FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_journal_snapshot "$1" invoice-check' \
    "$ROOT" "$dir/bad-kind" >/dev/null 2>&1; then
    fail "version 3 accepted a non ship/scout task kind"
  fi
  cp "$journal" "$dir/bad-label"
  perl -pi -e 's/^task_label=.*$/task_label=fm-invoice-check/' "$dir/bad-label"
  if FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_journal_snapshot "$1" invoice-check' \
    "$ROOT" "$dir/bad-label" >/dev/null 2>&1; then
    fail "version 3 accepted a non-derived task label"
  fi
  pass "Herdr projection journal: v1/v2 compatibility and strict readable v3 binding"
}

# Projection create pins both response-derived labels, then verifies the one
# exact readable tab and pane without selecting either by label.
test_projection_create_renames_and_verifies_both_labels() {
  local dir home log fake out calls
  dir="$TMP_ROOT/projection-readable-create"; home="$dir/home"; mkdir -p "$home/state"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspace":{"workspace_id":"w9"},"tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1"}}}'
  response "$dir" 2 '{"result":{"tab":{"tab_id":"w9:t2"},"root_pane":{"pane_id":"w9:p2"}}}'
  response "$dir" 3 '{"result":{"tab":{"workspace_id":"w9","tab_id":"w9:t2","label":"invoice-check · worker"}}}'
  response "$dir" 4 '{"result":{"pane":{"workspace_id":"w9","tab_id":"w9:t2","pane_id":"w9:p2","label":"invoice-check · worker"}}}'
  response "$dir" 5 '{"result":{"tabs":[{"workspace_id":"w9","tab_id":"w9:t2","label":"invoice-check · worker"}]}}'
  response "$dir" 6 '{"result":{"panes":[{"workspace_id":"w9","tab_id":"w9:t2","pane_id":"w9:p2"}]}}'
  response "$dir" 7 '{"result":{"pane":{"workspace_id":"w9","tab_id":"w9:t2","pane_id":"w9:p2","label":"invoice-check · worker"}}}'
  out=$(PATH="$fake:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$dir/responses" \
    HERDR_SESSION=fmtest bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_version_check() { return 0; }
      fm_backend_herdr_server_ensure() { return 0; }
      fm_backend_herdr_projection_focus_snapshot() { printf "captain-ws\tcaptain-tab"; }
      fm_backend_herdr_projection_focus_restore() { return 0; }
      fm_backend_herdr_workspace_prune_seeded_default_tab() { return 0; }
      fm_backend_herdr_projection_create_task /srv/payments "└ invoice-check · p:AbCdEfGhIjKlMnOpQrStUv" "invoice-check · worker" || exit 1
      printf "%s|%s" "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" "$FM_BACKEND_HERDR_PROJECTION_PANE_ID"
    ' "$ROOT") || fail "readable projection create failed"
  [ "$out" = 'w9:t2|w9:p2' ] || fail "readable projection create returned wrong ids: $out"
  calls=$(<"$log")
  assert_contains "$calls" $'tab\037rename\037w9:t2\037invoice-check · worker' "projection did not rename its response-derived tab"
  assert_contains "$calls" $'pane\037rename\037w9:p2\037invoice-check · worker' "projection did not rename its response-derived pane"
  assert_contains "$calls" $'pane\037get\037w9:p2' "projection did not verify its exact pane label"
  pass "Herdr projection create: response-derived tab and pane use the readable label"
}

# Live binding verification reads the exact pane and refuses a changed pane
# label even when workspace, tab, and pane-list identities still match.
test_projection_live_binding_refuses_pane_label_change() {
  local mode dir home log fake status
  for mode in exact renamed; do
    dir="$TMP_ROOT/projection-pane-$mode"; home="$dir/home"; mkdir -p "$home/state"
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"payments · primary"},{"workspace_id":"w2","label":"└ invoice-check · p:AbCdEfGhIjKlMnOpQrStUv"}]}}'
    response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"w2","tab_id":"w2:t2","label":"invoice-check · worker"}]}}'
    response "$dir" 3 '{"result":{"panes":[{"workspace_id":"w2","tab_id":"w2:t2","pane_id":"w2:p2"}]}}'
    if [ "$mode" = exact ]; then
      response "$dir" 4 '{"result":{"pane":{"workspace_id":"w2","tab_id":"w2:t2","pane_id":"w2:p2","label":"invoice-check · worker"}}}'
    else
      response "$dir" 4 '{"result":{"pane":{"workspace_id":"w2","tab_id":"w2:t2","pane_id":"w2:p2","label":"renamed"}}}'
    fi
    if run_adapter "$home" "$fake" "$log" fm_backend_herdr_projection_live_binding_matches \
      fmtest AbCdEfGhIjKlMnOpQrStUv w2 w2:t2 w2:p2 w1 \
      'payments · primary' '└ invoice-check · p:AbCdEfGhIjKlMnOpQrStUv' \
      'invoice-check · worker' >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    if [ "$mode" = exact ]; then
      [ "$status" -eq 0 ] || fail "exact pane label was refused"
    else
      [ "$status" -ne 0 ] || fail "changed pane label was accepted"
    fi
  done
  pass "Herdr projection binding: exact pane get enforces the readable pane label"
}

# Native-primary and task-project labels are distinct even when the project is
# itself named firstmate. The native tuple remains untouched by first task
# workspace creation.
test_native_primary_and_firstmate_project_are_distinct() {
  local dir home log fake out calls role
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_format_label firstmate primary' "$ROOT") \
    || fail "firstmate primary formatter refused"
  [ "$out" = 'firstmate · primary' ] || fail "firstmate primary label mismatch: $out"
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_format_label firstmate project' "$ROOT") \
    || fail "firstmate project formatter refused"
  [ "$out" = 'firstmate · project' ] || fail "firstmate project label mismatch: $out"
  for role in worker scout 'second mate'; do
    if bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_format_label firstmate "$1"' \
      "$ROOT" "$role" >/dev/null 2>&1; then
      fail "firstmate subject was accepted for role '$role'"
    fi
  done
  if bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_format_label payments primary' \
    "$ROOT" >/dev/null 2>&1; then
    fail "non-native subject was accepted for the primary role"
  fi

  dir="$TMP_ROOT/native-project-distinct"; home="$dir/home"; mkdir -p "$home/state"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"native","label":"firstmate · primary"}]}}'
  response "$dir" 2 '{"result":{"workspace":{"workspace_id":"project","label":"firstmate · project"},"tab":{"tab_id":"project:t1"},"root_pane":{"pane_id":"project:p1"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure fmtest /srv/firstmate) \
    || fail "firstmate project workspace creation refused beside native primary"
  [ "$out" = project ] || fail "firstmate project workspace returned '$out'"
  calls=$(<"$log")
  assert_contains "$calls" $'workspace\037create\037--cwd\037/srv/firstmate\037--label\037firstmate · project' \
    "firstmate task workspace was not created with its project role"
  assert_not_contains "$calls" $'workspace\037rename\037native' \
    "firstmate task workspace creation renamed the native primary tuple"
  pass "Herdr labels: native primary and firstmate project stay distinct"
}

# Herdr's honest native-session alias is one optional exact display field.
test_session_display_alias_metadata() {
  local home meta parent out
  home="$TMP_ROOT/session-alias/home"; mkdir -p "$home/state"
  printf 'research\n' > "$home/.fm-secondmate-home"
  meta="$home/state/alias.meta"
  metadata "$meta" ship /srv/payments w1 w1:t1 w1:p1
  printf 'herdr_session_display_label=Shared Herdr session\n' >> "$meta"
  FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_metadata_validate_record "$1"' \
    "$ROOT" "$meta" || fail "exact session display alias was refused"
  out=$(FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_session_display_label' "$ROOT")
  [ "$out" = 'Shared Herdr session' ] || fail "session display helper mismatch: $out"

  cp "$meta" "$home/state/foreign.meta"
  perl -pi -e 's/Shared Herdr session/Payments session/' "$home/state/foreign.meta"
  if FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_metadata_validate_record "$1"' \
    "$ROOT" "$home/state/foreign.meta" >/dev/null 2>&1; then
    fail "foreign project-specific session alias was accepted"
  fi
  parent="$home/state/.herdr-parent.meta"
  FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_parent_metadata_write "$1" research "$2" fmtest w2 w2:t2 w2:p2 \
      "research · second mate" "research · second mate"
  ' "$ROOT" "$parent" "$home" || fail "second-mate parent metadata publication failed"
  [ "$(grep '^herdr_session_display_label=' "$parent")" = \
    'herdr_session_display_label=Shared Herdr session' ] \
    || fail "second-mate parent metadata omitted the honest session alias"
  [ ! -e "$home/state/.herdr-parent.meta.tmp.$$" ] || fail "parent metadata left a predictable temporary file"
  pass "Herdr metadata: native-session alias is exact, display-only, and parent-published"
}

# The child-home parent publisher accepts only its complete exact schema and
# verifies both sides of the same-directory rename without trusting its exit.
test_parent_metadata_publication_safety() {
  local dir home fake parent target truncated out status nested leftovers
  dir="$TMP_ROOT/parent-publication"; home="$dir/home"; fake="$dir/bin"
  mkdir -p "$home/state" "$fake"
  printf 'research\n' > "$home/.fm-secondmate-home"
  parent="$home/state/.herdr-parent.meta"
  target="$dir/symlink-target"
  printf 'target bytes\n' > "$target"
  cat > "$fake/mv" <<'SH'
#!/usr/bin/env bash
set -u
case "${FM_TEST_MV_MODE:-pass}" in
  noop) exit 0 ;;
  symlink)
    /bin/rm -f "${2:-}" "${3:-}"
    /bin/ln -s "$FM_TEST_MV_TARGET" "${3:-}"
    ;;
  *) exec /bin/mv "$@" ;;
esac
SH
  chmod +x "$fake/mv"

  PATH="$fake:$PATH" FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_parent_metadata_write "$1" research "$2" fmtest w2 w2:t2 w2:p2 \
      "research · second mate" "research · second mate"
  ' "$ROOT" "$parent" "$home" || fail "absent parent destination was refused"
  [ -f "$parent" ] && [ ! -L "$parent" ] || fail "absent parent destination did not publish a regular file"
  [ "$(wc -l < "$parent" | tr -d '[:space:]')" = 15 ] || fail "published parent schema is not 15 fields"

  truncated="$dir/truncated.meta"
  head -n 14 "$parent" > "$truncated"
  chmod 0600 "$truncated"
  if FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_parent_metadata_validate_publish "$1" research "$2" fmtest w2 w2:t2 w2:p2 \
      "research · second mate" "research · second mate"
  ' "$ROOT" "$truncated" "$home" >/dev/null 2>&1; then
    fail "truncated parent candidate passed complete-schema validation"
  fi

  rm -f "$parent"
  mkdir "$parent"
  out=$(PATH="$fake:$PATH" FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_parent_metadata_write "$1" research "$2" fmtest w2 w2:t2 w2:p2 \
      "research · second mate" "research · second mate"
  ' "$ROOT" "$parent" "$home" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "directory parent destination was accepted"
  nested=$(find "$parent" -type f | wc -l | tr -d '[:space:]')
  [ "$nested" = 0 ] || fail "directory refusal moved a candidate inside the destination"
  rmdir "$parent"

  ln -s "$target" "$parent"
  out=$(PATH="$fake:$PATH" FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_parent_metadata_write "$1" research "$2" fmtest w2 w2:t2 w2:p2 \
      "research · second mate" "research · second mate"
  ' "$ROOT" "$parent" "$home" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "symlink parent destination was accepted"
  [ -L "$parent" ] && [ "$(cat "$target")" = 'target bytes' ] || fail "symlink refusal changed either path"
  rm -f "$parent"

  out=$(PATH="$fake:$PATH" FM_TEST_MV_MODE=noop FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_parent_metadata_write "$1" research "$2" fmtest w2 w2:t2 w2:p2 \
      "research · second mate" "research · second mate"
  ' "$ROOT" "$parent" "$home" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "false-success no-op parent rename was accepted"
  [ ! -e "$parent" ] && [ ! -L "$parent" ] || fail "no-op parent rename created a public path"
  leftovers=$(find "$home/state" -maxdepth 1 -name '.herdr-parent.meta.*' -type f | wc -l | tr -d '[:space:]')
  [ "$leftovers" = 0 ] || fail "no-op parent rename left a private candidate"

  out=$(PATH="$fake:$PATH" FM_TEST_MV_MODE=symlink FM_TEST_MV_TARGET="$target" \
    FM_HOME="$home" bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_parent_metadata_write "$1" research "$2" fmtest w2 w2:t2 w2:p2 \
        "research · second mate" "research · second mate"
    ' "$ROOT" "$parent" "$home" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "unsafe final parent path was accepted"
  [ -L "$parent" ] || fail "unsafe-final fixture did not leave the injected symlink"
  rm -f "$parent"
  pass "Herdr parent publication: complete schema refuses unsafe and false-success destinations"
}

# The private metadata-free fallback scans every running session and never
# chooses the first same-labeled tab.
test_bare_selector_global_uniqueness() {
  local dir home log fake out status
  dir="$TMP_ROOT/bare-duplicate"; home="$dir/home"; mkdir -p "$home/state"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"sessions":[{"name":"alpha","running":true},{"name":"bravo","running":true}]}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"wa","tab_id":"wa:ta","label":"same"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"workspace_id":"wa","tab_id":"wa:ta","pane_id":"wa:pa"}]}}'
  response "$dir" 4 '{"result":{"tabs":[{"workspace_id":"wb","tab_id":"wb:tb","label":"same"}]}}'
  response "$dir" 5 '{"result":{"panes":[{"workspace_id":"wb","tab_id":"wb:tb","pane_id":"wb:pb"}]}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_resolve_bare_selector same 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "cross-session duplicate bare selector chose one target"
  assert_contains "$out" 'not globally unique' "cross-session duplicate refusal was not clear"

  dir="$TMP_ROOT/bare-one"; home="$dir/home"; mkdir -p "$home/state"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"sessions":[{"name":"alpha","running":true},{"name":"bravo","running":true}]}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"wa","tab_id":"wa:ta","label":"one"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"workspace_id":"wa","tab_id":"wa:ta","pane_id":"wa:pa"}]}}'
  response "$dir" 4 '{"result":{"tabs":[{"workspace_id":"wb","tab_id":"wb:tb","label":"other"}]}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_resolve_bare_selector one) \
    || fail "one globally exact bare selector refused"
  [ "$out" = 'alpha:wa:pa' ] || fail "one exact bare selector returned '$out'"

  dir="$TMP_ROOT/bare-duplicate-identity"; home="$dir/home"; mkdir -p "$home/state"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"sessions":[{"name":"alpha","running":true}]}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"wa","tab_id":"wa:ta","label":"one"},{"workspace_id":"wa","tab_id":"wa:ta","label":"other"}]}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_resolve_bare_selector one 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate bare-selector tab identity chose one divergent row"
  assert_contains "$out" 'tab inventory is malformed' "duplicate tab identity refusal was not clear"

  dir="$TMP_ROOT/bare-reused-cross-session-identity"; home="$dir/home"; mkdir -p "$home/state"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"sessions":[{"name":"alpha","running":true},{"name":"bravo","running":true}]}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"one"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1"}]}}'
  response "$dir" 4 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"other"}]}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_resolve_bare_selector one) \
    || fail "cross-session reuse of tab ids was treated as one duplicate identity"
  [ "$out" = 'alpha:w1:p1' ] || fail "cross-session reused ids returned '$out'"

  dir="$TMP_ROOT/bare-multipane"; home="$dir/home"; mkdir -p "$home/state"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"sessions":[{"name":"alpha","running":true}]}'
  response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"wa","tab_id":"wa:ta","label":"many"}]}}'
  response "$dir" 3 '{"result":{"panes":[{"workspace_id":"wa","tab_id":"wa:ta","pane_id":"wa:p1"},{"workspace_id":"wa","tab_id":"wa:ta","pane_id":"wa:p2"}]}}'
  if run_adapter "$home" "$fake" "$log" fm_backend_herdr_resolve_bare_selector many >/dev/null 2>&1; then
    fail "multi-pane matching tab was accepted"
  fi
  pass "Herdr bare selector: one exact global tab succeeds; duplicates and multi-pane matches refuse"
}

test_native_primary_and_firstmate_project_are_distinct
test_session_display_alias_metadata
test_parent_metadata_publication_safety
test_bare_selector_global_uniqueness
test_projection_journal_versions_and_readable_binding
test_projection_create_renames_and_verifies_both_labels
test_projection_live_binding_refuses_pane_label_change
test_strict_adapter_owned_labels
test_malformed_metadata_refuses
test_prior_project_label_requires_exact_metadata
test_legacy_firstmate_workspace_requires_proved_native_separation
test_native_workspace_requires_exact_live_tuple
test_exact_workspace_discovery_refuses_semantic_duplicate
test_marked_workspace_collision_is_untouched
test_prefix_free_list_live_uses_only_exact_local_metadata
test_projected_list_live_uses_recorded_workspace_label
test_flat_list_live_refuses_arbitrary_recorded_workspace_label
test_missing_workspace_recreates_without_mutation
test_missing_tab_reuses_workspace_and_creates_task
test_missing_pane_reuses_workspace_without_close
test_list_live_keeps_healthy_and_skips_missing
test_list_live_unreadable_refuses
test_duplicate_task_label_refuses
test_husk_snapshot_requires_full_tuple_shape_and_agent_absence
test_legacy_empty_pane_label_rules
test_legacy_empty_pane_husk_recovers_twice
test_husk_revalidation_rolls_back_only_new_pane
test_new_object_label_failure_rolls_back_only_response_pane
