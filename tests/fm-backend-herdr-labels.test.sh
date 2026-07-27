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
  [ "$out" = 'payments · primary' ] || fail "primary label mismatch: $out"
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

# A primary workspace is adopted only through its complete metadata tuple;
# a second semantic label candidate makes discovery ambiguous.
test_exact_workspace_discovery_refuses_semantic_duplicate() {
  local dir home meta log fake out status calls
  dir="$TMP_ROOT/workspace-duplicate"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"; metadata "$meta" ship /srv/payments w1 w1:t1 w1:p1
  printf 'herdr_workspace_label=payments · primary\n' >> "$meta"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"payments · primary"},{"workspace_id":"decoy","label":"payments · primary"}]}}'
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

test_strict_adapter_owned_labels
test_malformed_metadata_refuses
test_exact_workspace_discovery_refuses_semantic_duplicate
test_marked_workspace_collision_is_untouched
test_prefix_free_list_live_uses_only_exact_local_metadata
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
