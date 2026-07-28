#!/usr/bin/env bash
# Focused fake-Herdr coverage for spawn recovery evidence separation.
# No live Herdr command or non-Herdr runtime implementation is read.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-herdr-recovery.XXXXXX")
BASE_PATH=$PATH
TASK_TMP_PATHS=
cleanup() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -rf "$path"
  done <<EOF
$TASK_TMP_PATHS
EOF
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3" ;; *) : ;; esac; }

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
[ ! -f "$FM_HERDR_RESPONSES/$count.out" ] || cat "$FM_HERDR_RESPONSES/$count.out"
exit "$status"
SH
  chmod +x "$dir/bin/herdr"
  printf '%s' "$dir/bin"
}

# Stateful fake used only by the full-path fixtures below. It models the
# production Herdr calls made by fm-herdr-primary-labels.sh and fm-spawn.sh,
# persists exact workspace/tab/pane state in one temporary JSON file, and logs
# every command. It never contacts a live Herdr session.
make_stateful_herdr() {  # <fixture-dir>
  local dir=$1 socket="$1/fake.sock"
  mkdir -p "$dir/bin"
  : > "$socket"
  printf '{"next":10,"session":"fmtest","socket":%s,"workspaces":[],"tabs":[],"panes":[],"agents":{},"pending":{},"faults":{}}\n' \
    "$(printf '%s' "$socket" | jq -Rs .)" > "$dir/state.json"
  : > "$dir/herdr.log"
  cat > "$dir/bin/herdr" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

state_path = os.environ["FM_FAKE_HERDR_STATE"]
log_path = os.environ["FM_HERDR_LOG"]
args = sys.argv[1:]
with open(log_path, "a", encoding="utf-8") as log:
    log.write("\x1f".join(args) + "\n")
if len(args) >= 2 and args[-2] == "--session":
    args = args[:-2]
with open(state_path, encoding="utf-8") as src:
    state = json.load(src)


def save():
    tmp = state_path + ".tmp." + str(os.getpid())
    with open(tmp, "w", encoding="utf-8") as out:
        json.dump(state, out, sort_keys=True, separators=(",", ":"))
        out.write("\n")
    os.replace(tmp, state_path)


def emit(value):
    print(json.dumps(value, separators=(",", ":")))


def option(name, default=""):
    try:
        return args[args.index(name) + 1]
    except (ValueError, IndexError):
        return default


def workspace(wsid):
    return next((row for row in state["workspaces"] if row["workspace_id"] == wsid), None)


def tab(tab_id):
    return next((row for row in state["tabs"] if row["tab_id"] == tab_id), None)


def pane(pane_id):
    return next((row for row in state["panes"] if row["pane_id"] == pane_id), None)


def normalize_focus():
    if not state["workspaces"]:
        return
    focused = [row for row in state["workspaces"] if row.get("focused")]
    if len(focused) != 1:
        for row in state["workspaces"]:
            row["focused"] = False
        state["workspaces"][0]["focused"] = True
        focused = [state["workspaces"][0]]
    current = focused[0]
    tabs = [row for row in state["tabs"] if row["workspace_id"] == current["workspace_id"]]
    active = next((row for row in tabs if row["tab_id"] == current.get("active_tab_id")), None)
    if active is None and tabs:
        active = tabs[0]
        current["active_tab_id"] = active["tab_id"]
    for row in state["tabs"]:
        row["focused"] = bool(active and row["tab_id"] == active["tab_id"])


cmd = tuple(args[:2])
if cmd == ("status", "--json"):
    emit({"client": {"version": "0.7.5", "protocol": 16}, "server": {"running": True}})
elif cmd == ("session", "list"):
    emit({"sessions": [{"name": state["session"], "running": True, "socket_path": state["socket"]}]})
elif cmd == ("workspace", "list"):
    normalize_focus()
    save()
    emit({"result": {"workspaces": state["workspaces"]}})
elif cmd == ("workspace", "get"):
    row = workspace(args[2])
    emit({"result": {"workspace": row}} if row else {"error": {"code": "workspace_not_found"}})
elif cmd == ("workspace", "create"):
    n = state["next"]
    state["next"] += 1
    wsid = f"w{n}"
    tab_id = f"{wsid}:t{n}"
    pane_id = f"{wsid}:p{n}"
    label = option("--label")
    cwd = option("--cwd")
    focused = not any(row.get("focused") for row in state["workspaces"])
    state["workspaces"].append({"workspace_id": wsid, "label": label, "focused": focused, "active_tab_id": tab_id})
    state["tabs"].append({"workspace_id": wsid, "tab_id": tab_id, "label": "1", "focused": focused})
    state["panes"].append({"workspace_id": wsid, "tab_id": tab_id, "pane_id": pane_id, "label": "", "cwd": cwd, "foreground_cwd": cwd})
    save()
    emit({"result": {"workspace": {"workspace_id": wsid, "label": label}, "tab": {"tab_id": tab_id}, "root_pane": {"pane_id": pane_id}}})
elif cmd == ("workspace", "rename"):
    row = workspace(args[2])
    if not row:
        emit({"error": {"code": "workspace_not_found"}})
    else:
        row["label"] = args[3]
        save()
        emit({"result": {"workspace": {"workspace_id": row["workspace_id"], "label": row["label"]}}})
elif cmd == ("tab", "list"):
    wsid = option("--workspace")
    rows = [row for row in state["tabs"] if not wsid or row["workspace_id"] == wsid]
    emit({"result": {"tabs": rows}})
elif cmd == ("tab", "get"):
    row = tab(args[2])
    emit({"result": {"tab": row}} if row else {"error": {"code": "tab_not_found"}})
elif cmd == ("tab", "create"):
    n = state["next"]
    state["next"] += 1
    wsid = option("--workspace")
    tab_id = f"{wsid}:t{n}"
    pane_id = f"{wsid}:p{n}"
    label = option("--label")
    cwd = option("--cwd")
    state["tabs"].append({"workspace_id": wsid, "tab_id": tab_id, "label": label, "focused": False})
    state["panes"].append({"workspace_id": wsid, "tab_id": tab_id, "pane_id": pane_id, "label": label, "cwd": cwd, "foreground_cwd": cwd})
    save()
    emit({"result": {"tab": {"tab_id": tab_id}, "root_pane": {"pane_id": pane_id}}})
elif cmd == ("tab", "rename"):
    row = tab(args[2])
    if state["faults"].pop("fail_next_tab_rename", False):
        save()
        emit({"result": {"tab": {"workspace_id": row["workspace_id"] if row else "", "tab_id": args[2], "label": "fault-injected"}}})
    elif not row:
        emit({"error": {"code": "tab_not_found"}})
    else:
        row["label"] = args[3]
        save()
        emit({"result": {"tab": {"workspace_id": row["workspace_id"], "tab_id": row["tab_id"], "label": row["label"]}}})
elif cmd == ("tab", "focus"):
    row = tab(args[2])
    if not row:
        emit({"error": {"code": "tab_not_found"}})
    else:
        for item in state["workspaces"]:
            item["focused"] = item["workspace_id"] == row["workspace_id"]
            if item["focused"]:
                item["active_tab_id"] = row["tab_id"]
        normalize_focus()
        save()
        emit({"result": {"tab": row}})
elif cmd == ("tab", "close"):
    tab_id = args[2]
    state["tabs"] = [row for row in state["tabs"] if row["tab_id"] != tab_id]
    state["panes"] = [row for row in state["panes"] if row["tab_id"] != tab_id]
    normalize_focus()
    save()
    emit({})
elif cmd == ("pane", "list"):
    wsid = option("--workspace")
    rows = [row for row in state["panes"] if not wsid or row["workspace_id"] == wsid]
    emit({"result": {"panes": rows}})
elif cmd == ("pane", "get"):
    row = pane(args[2])
    emit({"result": {"pane": row}} if row else {"error": {"code": "pane_not_found"}})
elif cmd == ("pane", "rename"):
    row = pane(args[2])
    if not row:
        emit({"error": {"code": "pane_not_found"}})
    else:
        row["label"] = args[3]
        save()
        emit({"result": {"pane": {"workspace_id": row["workspace_id"], "tab_id": row["tab_id"], "pane_id": row["pane_id"], "label": row["label"]}}})
elif cmd == ("pane", "close"):
    pane_id = args[2]
    old = pane(pane_id)
    state["panes"] = [row for row in state["panes"] if row["pane_id"] != pane_id]
    if old and not any(row["tab_id"] == old["tab_id"] for row in state["panes"]):
        state["tabs"] = [row for row in state["tabs"] if row["tab_id"] != old["tab_id"]]
    for item in list(state["workspaces"]):
        if not any(row["workspace_id"] == item["workspace_id"] for row in state["tabs"]):
            state["workspaces"].remove(item)
    state["agents"].pop(pane_id, None)
    normalize_focus()
    save()
    emit({})
elif cmd == ("pane", "run"):
    row = pane(args[2])
    if row and len(args) > 3 and args[3] == "treehouse get":
        row["foreground_cwd"] = os.environ["FM_FAKE_HERDR_WORKTREE"]
        save()
    emit({})
elif cmd == ("pane", "send-text"):
    state["pending"][args[2]] = args[3] if len(args) > 3 else ""
    save()
    emit({})
elif cmd == ("pane", "send-keys"):
    state["pending"].pop(args[2], None)
    save()
    emit({})
elif cmd == ("pane", "process-info"):
    pane_id = option("--pane")
    emit({"result": {"type": "pane_process_info", "process_info": {"pane_id": pane_id, "foreground_processes": [{"pid": int(os.environ["FM_FAKE_HERDR_OWNER_PID"])}]}}})
elif cmd == ("agent", "get"):
    pane_id = args[2]
    status = state["agents"].get(pane_id)
    emit({"result": {"agent": {"agent_status": status}}} if status else {"error": {"code": "agent_not_found"}})
else:
    emit({})
PY
  cat > "$dir/bin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/bin/mv" <<'SH'
#!/usr/bin/env bash
set -u
candidate=${2:-}
destination=${3:-}
if [ -n "${FM_TEST_FAIL_PUBLIC_PATH:-}" ] \
   && [ "$destination" = "$FM_TEST_FAIL_PUBLIC_PATH" ] \
   && [ ! -e "${FM_TEST_FAIL_MARKER:?}" ]; then
  grep '^herdr_pane_id=' "$candidate" 2>/dev/null | cut -d= -f2- > "$FM_TEST_FAIL_MARKER" || : > "$FM_TEST_FAIL_MARKER"
  exit 92
fi
if [ -n "${FM_TEST_UNSAFE_FINAL_PATH:-}" ] \
   && [ "$destination" = "$FM_TEST_UNSAFE_FINAL_PATH" ] \
   && [ ! -e "${FM_TEST_UNSAFE_FINAL_MARKER:?}" ]; then
  grep '^herdr_pane_id=' "$candidate" 2>/dev/null | cut -d= -f2- > "$FM_TEST_UNSAFE_FINAL_MARKER" \
    || : > "$FM_TEST_UNSAFE_FINAL_MARKER"
  /bin/rm -f "$candidate" "$destination"
  /bin/mkdir "$destination"
  exit 0
fi
exec /bin/mv "$@"
SH
  chmod +x "$dir/bin/herdr" "$dir/bin/treehouse" "$dir/bin/sleep" "$dir/bin/mv"
  printf '%s' "$dir/bin"
}

response() { printf '%s\n' "$3" > "$1/responses/$2.out"; }
run_adapter() {  # <home> <fake-bin> <log> <command> [args...]
  local home=$1 fake=$2 log=$3 command=$4
  shift 4
  PATH="$fake:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" \
    FM_HERDR_RESPONSES="${fake%/bin}/responses" \
    bash -c '. "$0/bin/backends/herdr.sh"; "$1" "${@:2}"' "$ROOT" "$command" "$@"
}
write_task_meta() {  # <path> <project> <workspace> <tab> <pane> <workspace-label>
  printf '%s\n' \
    'backend=herdr' 'kind=ship' "project=$2" 'herdr_session=fmtest' \
    "herdr_workspace_id=$3" "herdr_tab_id=$4" "herdr_pane_id=$5" \
    'display_label=invoice-check · worker' "herdr_workspace_label=$6" \
    'herdr_tab_label=invoice-check · worker' 'herdr_pane_label=invoice-check · worker' > "$1"
}

state_update() {  # <state> <jq-args...>
  local state=$1 tmp="$1.tmp.$$"
  shift
  jq "$@" "$state" > "$tmp" && /bin/mv "$tmp" "$state"
}

make_project_and_worktree() {  # <project> <worktree> [clone-firstmate]
  local project=$1 worktree=$2 clone_firstmate=${3:-0}
  mkdir -p "$(dirname "$project")" "$(dirname "$worktree")"
  if [ "$clone_firstmate" = 1 ]; then
    git clone -q "$ROOT" "$project" || return 1
  else
    git -C "$(dirname "$project")" init -q "$(basename "$project")" || return 1
    printf '# fake Herdr spawn project\n' > "$project/README.md"
    git -C "$project" add README.md
    git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm init
  fi
  git -C "$project" worktree add -q --detach "$worktree" HEAD
}

make_worker_home() {  # <home> <task-id>
  mkdir -p "$1/state" "$1/config" "$1/data/$2"
  printf 'Safe full-spawn fake Herdr fixture.\n' > "$1/data/$2/brief.md"
}

track_task_tmp() {  # <task-id>
  TASK_TMP_PATHS="${TASK_TMP_PATHS}/tmp/fm-$1"$'\n'
}

run_real_worker_spawn() {  # <id> <home> <project> <worktree> <fakebin> <state> <log> [fail-path] [fail-marker]
  local id=$1 home=$2 project=$3 worktree=$4 fake=$5 state=$6 log=$7 fail_path=${8:-} fail_marker=${9:-}
  track_task_tmp "$id"
  PATH="$fake:$BASE_PATH" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" HERDR_SESSION=fmtest \
    FM_FAKE_HERDR_STATE="$state" FM_HERDR_LOG="$log" \
    FM_FAKE_HERDR_WORKTREE="$worktree" FM_TEST_FAIL_PUBLIC_PATH="$fail_path" \
    FM_TEST_FAIL_MARKER="$fail_marker" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'true'" --backend herdr
}

write_full_projected_meta() {  # <path> <id> <project> <worktree> <workspace> <tab> <pane> <workspace-label> <task-label>
  cat > "$1" <<EOF
window=fmtest:$7
worktree=$4
project=$3
harness=sh
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$2
model=default
effort=default
backend=herdr
herdr_session=fmtest
herdr_session_display_label=Shared Herdr session
herdr_workspace_id=$5
herdr_tab_id=$6
herdr_pane_id=$7
display_label=$9
herdr_workspace_label=$8
herdr_tab_label=$9
herdr_pane_label=$9
EOF
}

assert_old_projection_untouched() {  # <state> <log> <workspace> <tab> <pane> <label>
  local state=$1 log=$2 workspace=$3 tab=$4 pane=$5 label=$6 calls
  jq -e --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" --arg label "$label" '
    ([.workspaces[] | select(.workspace_id == $workspace and .label == $label)] | length) == 1
    and ([.tabs[] | select(.workspace_id == $workspace and .tab_id == $tab)] | length) == 1
    and ([.panes[] | select(.workspace_id == $workspace and .tab_id == $tab and .pane_id == $pane)] | length) == 1
  ' "$state" >/dev/null || fail "full spawn changed the old projected child tuple"
  calls=$(cat "$log")
  assert_not_contains "$calls" "workspace"$'\037'"rename"$'\037'"$workspace" \
    "full fallback renamed the old projected child"
  assert_not_contains "$calls" "tab"$'\037'"close"$'\037'"$tab" \
    "full fallback closed the old projected child tab"
  assert_not_contains "$calls" "pane"$'\037'"close"$'\037'"$pane" \
    "full fallback closed the old projected child pane"
  assert_not_contains "$calls" "pane"$'\037'"run"$'\037'"$pane" \
    "full fallback entered the old projected child"
}

# Converge the fake native primary through its real owner, then run the real
# worker-spawn entry point against an isolated copy whose basename is
# firstmate. The native tuple must remain distinct and byte-stable afterwards.
test_real_spawn_keeps_native_primary_and_firstmate_project_distinct() {
  local dir home fake state log socket owner_script project worktree id native_after meta project_workspace
  dir="$TMP_ROOT/full-native-firstmate"; home="$dir/home"; mkdir -p "$home/state" "$home/config" "$home/data"
  fake=$(make_stateful_herdr "$dir")
  state="$dir/state.json"; log="$dir/herdr.log"; socket=$(jq -r '.socket' "$state")
  # shellcheck disable=SC2016  # jq variables, not shell expansion
  state_update "$state" --arg root "$ROOT" '
    .workspaces = [{workspace_id:"native",label:"firstmate",focused:true,active_tab_id:"native:t1"}]
    | .tabs = [{workspace_id:"native",tab_id:"native:t1",label:"1",focused:true}]
    | .panes = [{workspace_id:"native",tab_id:"native:t1",pane_id:"native:p1",label:"",cwd:$root,foreground_cwd:$root}]
  '
  owner_script="$dir/codex-primary-parent.js"
  cat > "$owner_script" <<'JS'
const fs = require("fs");
const { spawnSync } = require("child_process");
fs.writeFileSync(process.env.FM_PRIMARY_LOCK, String(process.pid) + "\n");
const env = { ...process.env, FM_FAKE_HERDR_OWNER_PID: String(process.pid) };
const result = spawnSync(process.env.FM_PRIMARY_SCRIPT, [], {
  cwd: process.env.FM_ROOT_OVERRIDE,
  env,
  stdio: "inherit",
});
process.exit(result.status === null ? 1 : result.status);
JS
  (
    cd "$ROOT" || exit 1
    PATH="$fake:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_FAKE_HERDR_STATE="$state" FM_HERDR_LOG="$log" \
      FM_FAKE_HERDR_WORKTREE="$dir/unused" FM_PRIMARY_LOCK="$home/state/.lock" \
      FM_PRIMARY_SCRIPT="$ROOT/bin/fm-herdr-primary-labels.sh" HERDR_ENV=1 \
      HERDR_SOCKET_PATH="$socket" HERDR_WORKSPACE_ID=native HERDR_TAB_ID=native:t1 \
      HERDR_PANE_ID=native:p1 node "$owner_script"
  ) || fail "real native-primary label owner did not converge against the fake Herdr command"
  native_after=$(jq -c '
    {workspace:(.workspaces[]|select(.workspace_id=="native")),
     tab:(.tabs[]|select(.tab_id=="native:t1")),
     pane:(.panes[]|select(.pane_id=="native:p1"))}
  ' "$state")
  printf '%s' "$native_after" | jq -e '
    .workspace.label == "firstmate · primary"
    and .tab.label == "firstmate · primary"
    and .pane.label == "firstmate · primary"
  ' >/dev/null || fail "native primary did not converge to its distinct readable label"

  project="$dir/copy/firstmate"; worktree="$dir/worktrees/firstmate-worker"
  make_project_and_worktree "$project" "$worktree" 1 || fail "could not create the isolated Firstmate repository copy"
  id="native-project-$$"; make_worker_home "$home" "$id"
  run_real_worker_spawn "$id" "$home" "$project" "$worktree" "$fake" "$state" "$log" \
    > "$dir/spawn.out" 2> "$dir/spawn.err" \
    || fail "real Firstmate-project worker spawn failed: $(cat "$dir/spawn.err")"
  meta="$home/state/$id.meta"
  project_workspace=$(grep '^herdr_workspace_id=' "$meta" | cut -d= -f2-)
  [ -n "$project_workspace" ] && [ "$project_workspace" != native ] \
    || fail "Firstmate project worker reused the native primary workspace"
  [ "$(grep '^herdr_workspace_label=' "$meta")" = 'herdr_workspace_label=firstmate · project' ] \
    || fail "Firstmate project worker did not publish the project role"
  [ "$(jq -r --arg workspace "$project_workspace" '.workspaces[] | select(.workspace_id == $workspace) | .label' "$state")" = 'firstmate · project' ] \
    || fail "real worker spawn did not create the distinct Firstmate project workspace"
  [ "$(jq -c '
    {workspace:(.workspaces[]|select(.workspace_id=="native")),
     tab:(.tabs[]|select(.tab_id=="native:t1")),
     pane:(.panes[]|select(.pane_id=="native:p1"))}
  ' "$state")" = "$native_after" ] || fail "real worker spawn mutated the converged native primary tuple"
  pass "Herdr full spawn: native primary and Firstmate project remain distinct"
}

prepare_full_projection_case() {  # <dir> <version> <focus-child:0|1> <fail-reclaim-label:0|1>
  local dir=$1 version=$2 focus_child=$3 fail_label=$4 task_label parent_focus child_focus
  FULL_ID="projection-v${version}-${focus_child}-${fail_label}-$$"
  FULL_HOME="$dir/home"
  FULL_PROJECT="$dir/payments"
  FULL_WORKTREE="$dir/worktree"
  FULL_TOKEN=AbCdEfGhIjKlMnOpQrStUv
  FULL_CHILD_LABEL="└ $FULL_ID · p:$FULL_TOKEN"
  FULL_PARENT_LABEL='payments · primary'
  make_project_and_worktree "$FULL_PROJECT" "$FULL_WORKTREE" \
    || fail "could not create v$version full-spawn project fixture"
  make_worker_home "$FULL_HOME" "$FULL_ID"
  : > "$FULL_HOME/config/herdr-presentation-spaces"
  FULL_FAKE=$(make_stateful_herdr "$dir")
  FULL_STATE="$dir/state.json"
  FULL_LOG="$dir/herdr.log"
  task_label="$FULL_ID · worker"
  [ "$version" != 2 ] || task_label="fm-$FULL_ID"
  parent_focus=true; child_focus=false
  if [ "$focus_child" = 1 ]; then parent_focus=false; child_focus=true; fi
  # shellcheck disable=SC2016  # jq variables, not shell expansion
  state_update "$FULL_STATE" \
    --arg project "$FULL_PROJECT" --arg worktree "$FULL_WORKTREE" \
    --arg parent_label "$FULL_PARENT_LABEL" --arg child_label "$FULL_CHILD_LABEL" \
    --arg task_label "$task_label" --argjson parent_focus "$parent_focus" \
    --argjson child_focus "$child_focus" --argjson fail_label "$fail_label" '
      .next = 20
      | .workspaces = [
          {workspace_id:"parent",label:$parent_label,focused:$parent_focus,active_tab_id:"parent:t0"},
          {workspace_id:"child",label:$child_label,focused:$child_focus,active_tab_id:"child:t1"}
        ]
      | .tabs = [
          {workspace_id:"parent",tab_id:"parent:t0",label:"anchor · worker",focused:$parent_focus},
          {workspace_id:"child",tab_id:"child:t1",label:$task_label,focused:$child_focus}
        ]
      | .panes = [
          {workspace_id:"parent",tab_id:"parent:t0",pane_id:"parent:p0",label:"anchor · worker",cwd:$project,foreground_cwd:$project},
          {workspace_id:"child",tab_id:"child:t1",pane_id:"child:p1",label:$task_label,cwd:$project,foreground_cwd:$worktree}
        ]
      | .faults.fail_next_tab_rename = ($fail_label == 1)
    '
  write_full_projected_meta "$FULL_HOME/state/$FULL_ID.meta" "$FULL_ID" \
    "$FULL_PROJECT" "$FULL_WORKTREE" child child:t1 child:p1 \
    "$FULL_CHILD_LABEL" "$task_label"
  FULL_JOURNAL="$FULL_HOME/state/$FULL_ID.herdr-presentation"
  case "$version" in
    1)
      printf '%s\n' 'version=1' "task_id=$FULL_ID" "projection_id=$FULL_TOKEN" > "$FULL_JOURNAL"
      ;;
    2)
      printf '%s\n' \
        'version=2' "task_id=$FULL_ID" "projection_id=$FULL_TOKEN" \
        "home=$(cd "$FULL_HOME" && pwd -P)" 'session=fmtest' \
        'workspace_id=child' 'tab_id=child:t1' 'pane_id=child:p1' \
        'parent_workspace_id=parent' "parent_label=$FULL_PARENT_LABEL" \
        "workspace_label=$FULL_CHILD_LABEL" "task_label=$task_label" > "$FULL_JOURNAL"
      ;;
    3)
      printf '%s\n' \
        'version=3' "task_id=$FULL_ID" 'task_kind=ship' "projection_id=$FULL_TOKEN" \
        "home=$(cd "$FULL_HOME" && pwd -P)" 'session=fmtest' \
        'workspace_id=child' 'tab_id=child:t1' 'pane_id=child:p1' \
        'parent_workspace_id=parent' "parent_label=$FULL_PARENT_LABEL" \
        "workspace_label=$FULL_CHILD_LABEL" "task_label=$task_label" > "$FULL_JOURNAL"
      ;;
    *) fail "unsupported full projection fixture version $version" ;;
  esac
  : > "$FULL_LOG"
}

# Drive complete fm-spawn.sh v1, v2, and v3 recovery paths. V1 excludes its
# token-bound child. V2 refuses active-tab reclaim before mutation. V3 rolls
# back a replacement whose label response fails. Every path then creates in or
# selects only a lawful flat parent and never enters or closes the old child.
test_real_spawn_projection_fallback_and_reclaim_refusals() {
  local dir meta final_workspace calls

  dir="$TMP_ROOT/full-v1-fallback"
  prepare_full_projection_case "$dir" 1 1 0
  run_real_worker_spawn "$FULL_ID" "$FULL_HOME" "$FULL_PROJECT" "$FULL_WORKTREE" \
    "$FULL_FAKE" "$FULL_STATE" "$FULL_LOG" > "$dir/out" 2> "$dir/err" \
    || fail "real v1 flat fallback failed: $(cat "$dir/err")"
  meta="$FULL_HOME/state/$FULL_ID.meta"
  final_workspace=$(grep '^herdr_workspace_id=' "$meta" | cut -d= -f2-)
  [ -n "$final_workspace" ] && [ "$final_workspace" != child ] && [ "$final_workspace" != parent ] \
    || fail "real v1 fallback adopted its child or unowned prior-label parent"
  assert_old_projection_untouched "$FULL_STATE" "$FULL_LOG" child child:t1 child:p1 "$FULL_CHILD_LABEL"

  dir="$TMP_ROOT/full-v2-prior-parent"
  prepare_full_projection_case "$dir" 2 1 0
  run_real_worker_spawn "$FULL_ID" "$FULL_HOME" "$FULL_PROJECT" "$FULL_WORKTREE" \
    "$FULL_FAKE" "$FULL_STATE" "$FULL_LOG" > "$dir/out" 2> "$dir/err" \
    || fail "real v2 prior-parent fallback failed: $(cat "$dir/err")"
  meta="$FULL_HOME/state/$FULL_ID.meta"
  [ "$(grep '^herdr_workspace_id=' "$meta")" = herdr_workspace_id=parent ] \
    || fail "real v2 prior-parent fallback did not select the exact journal parent"
  [ "$(jq -r '.workspaces[] | select(.workspace_id == "parent") | .label' "$FULL_STATE")" = 'payments · project' ] \
    || fail "real v2 fallback did not migrate only its exact prior-label parent"
  assert_old_projection_untouched "$FULL_STATE" "$FULL_LOG" child child:t1 child:p1 "$FULL_CHILD_LABEL"

  dir="$TMP_ROOT/full-v2-active-refusal"
  prepare_full_projection_case "$dir" 2 1 0
  state_update "$FULL_STATE" '(.workspaces[] | select(.workspace_id == "parent") | .label) = "payments · project"'
  perl -pi -e 's/^parent_label=.*/parent_label=payments · project/' "$FULL_JOURNAL"
  run_real_worker_spawn "$FULL_ID" "$FULL_HOME" "$FULL_PROJECT" "$FULL_WORKTREE" \
    "$FULL_FAKE" "$FULL_STATE" "$FULL_LOG" > "$dir/out" 2> "$dir/err" \
    || fail "real v2 active-tab reclaim refusal did not fall back: $(cat "$dir/err")"
  meta="$FULL_HOME/state/$FULL_ID.meta"
  [ "$(grep '^herdr_workspace_id=' "$meta")" = herdr_workspace_id=parent ] \
    || fail "real v2 fallback did not select the exact journal parent"
  grep -F 'would replace the active tab; spawning flat' "$dir/err" >/dev/null \
    || fail "real v2 fixture did not exercise active-tab reclaim refusal: $(cat "$dir/err")"
  assert_old_projection_untouched "$FULL_STATE" "$FULL_LOG" child child:t1 child:p1 "$FULL_CHILD_LABEL"

  dir="$TMP_ROOT/full-v3-label-rollback"
  prepare_full_projection_case "$dir" 3 0 1
  state_update "$FULL_STATE" '(.workspaces[] | select(.workspace_id == "parent") | .label) = "payments · project"'
  perl -pi -e 's/^parent_label=.*/parent_label=payments · project/' "$FULL_JOURNAL"
  run_real_worker_spawn "$FULL_ID" "$FULL_HOME" "$FULL_PROJECT" "$FULL_WORKTREE" \
    "$FULL_FAKE" "$FULL_STATE" "$FULL_LOG" > "$dir/out" 2> "$dir/err" \
    || fail "real v3 replacement-label refusal did not fall back: $(cat "$dir/err")"
  meta="$FULL_HOME/state/$FULL_ID.meta"
  [ "$(grep '^herdr_workspace_id=' "$meta")" = herdr_workspace_id=parent ] \
    || fail "real v3 fallback did not select the exact journal parent"
  [ "$(jq -r '.faults.fail_next_tab_rename // false' "$FULL_STATE")" = false ] \
    || fail "real v3 fixture did not consume its reclaim label fault: $(cat "$dir/err")"
  calls=$(cat "$FULL_LOG")
  assert_contains "$calls" "tab"$'\037'"create"$'\037'"--workspace"$'\037'"child" \
    "real v3 fixture did not reach replacement creation inside the exact child"
  grep -F 'could not verify its replacement labels; spawning flat' "$dir/err" >/dev/null \
    || fail "real v3 fixture did not report the label-verification refusal"
  assert_old_projection_untouched "$FULL_STATE" "$FULL_LOG" child child:t1 child:p1 "$FULL_CHILD_LABEL"
  pass "Herdr full spawn: v1 and v2/v3 fallback never adopts or enters the old projected child"
}

# Missing, foreign-label, and duplicate exact parents must refuse in both v2
# and v3 after reclaim declines, before any create, rename, close, or launch.
test_real_spawn_exact_journal_parent_refusals() {
  local version layout dir before after out status mutations
  for version in 2 3; do
    for layout in missing foreign duplicate; do
      dir="$TMP_ROOT/full-v${version}-parent-$layout"
      prepare_full_projection_case "$dir" "$version" 1 0
      case "$layout" in
        missing) state_update "$FULL_STATE" '.workspaces |= [.[] | select(.workspace_id != "parent")] | .tabs |= [.[] | select(.workspace_id != "parent")] | .panes |= [.[] | select(.workspace_id != "parent")]' ;;
        foreign) state_update "$FULL_STATE" '(.workspaces[] | select(.workspace_id == "parent") | .label) = "foreign"' ;;
        duplicate) state_update "$FULL_STATE" '.workspaces += [{workspace_id:"parent",label:"payments · primary",focused:false,active_tab_id:"parent:t0"}]' ;;
      esac
      before=$(cksum < "$FULL_HOME/state/$FULL_ID.meta")
      out=$(run_real_worker_spawn "$FULL_ID" "$FULL_HOME" "$FULL_PROJECT" "$FULL_WORKTREE" \
        "$FULL_FAKE" "$FULL_STATE" "$FULL_LOG" 2>&1); status=$?
      [ "$status" -ne 0 ] || fail "v$version $layout exact journal parent unexpectedly launched"
      after=$(cksum < "$FULL_HOME/state/$FULL_ID.meta")
      [ "$after" = "$before" ] || fail "v$version $layout refusal replaced projected metadata"
      mutations=$(awk -F $'\037' '
        (($1 == "workspace" && ($2 == "create" || $2 == "rename")) ||
         ($1 == "tab" && ($2 == "create" || $2 == "rename" || $2 == "close")) ||
         ($1 == "pane" && ($2 == "rename" || $2 == "close" || $2 == "run"))) { print }
      ' "$FULL_LOG")
      [ -z "$mutations" ] || fail "v$version $layout exact parent refusal mutated Herdr: $mutations"
      assert_old_projection_untouched "$FULL_STATE" "$FULL_LOG" child child:t1 child:p1 "$FULL_CHILD_LABEL"
      assert_contains "$out" 'failed to ensure herdr workspace' \
        "v$version $layout exact parent refusal did not stop in flat-parent resolution"
    done
  done
  pass "Herdr full spawn: v2/v3 exact journal parent rules refuse missing, foreign, and duplicate ids"
}

# A v1 journal has no parent id. Its projected task record is excluded from
# normal project discovery, so the child can neither be adopted nor mutated.
# An unowned same-label flat parent still refuses.
test_v1_flat_fallback_excludes_projected_child() {
  local dir home meta log fake out status calls token child
  token=AbCdEfGhIjKlMnOpQrStUv
  child="└ invoice-check · p:$token"

  dir="$TMP_ROOT/v1-create"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"
  write_task_meta "$meta" /srv/payments child child:t1 child:p1 "$child"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 "{\"result\":{\"workspaces\":[{\"workspace_id\":\"child\",\"label\":\"$child\"}]}}"
  response "$dir" 2 '{"result":{"workspace":{"workspace_id":"parent","label":"payments · project"},"tab":{"tab_id":"parent:t1"},"root_pane":{"pane_id":"parent:p1"}}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
    fmtest /srv/payments '' "$meta") || fail "v1 fallback could not create a lawful flat parent: $out"
  [ "$out" = parent ] || fail "v1 fallback returned '$out'"
  calls=$(cat "$log")
  assert_not_contains "$calls" $'rename\037child' "v1 fallback renamed its projected child"
  assert_not_contains "$calls" $'close\037child' "v1 fallback closed its projected child"

  dir="$TMP_ROOT/v1-unowned-parent"; home="$dir/home"; mkdir -p "$home/state"
  meta="$home/state/invoice-check.meta"
  write_task_meta "$meta" /srv/payments child child:t1 child:p1 "$child"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 "{\"result\":{\"workspaces\":[{\"workspace_id\":\"child\",\"label\":\"$child\"},{\"workspace_id\":\"foreign\",\"label\":\"payments · project\"}]}}"
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
    fmtest /srv/payments '' "$meta" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "v1 fallback adopted an unowned same-label parent"
  calls=$(cat "$log")
  assert_not_contains "$calls" $'workspace\037create' "v1 unowned-parent refusal created a workspace"
  assert_not_contains "$calls" $'workspace\037rename' "v1 unowned-parent refusal renamed a workspace"
  pass "Herdr spawn recovery: v1 flat fallback excludes the projected child"
}

# V2/v3 fallbacks select the exact journal parent id. The prior project-primary
# label migrates only on that id. Missing, foreign, or duplicate parent ids
# refuse before mutation.
test_v2_v3_flat_fallback_uses_exact_parent() {
  local version dir home log fake out status calls layout
  for version in 2 3; do
    dir="$TMP_ROOT/v$version-parent"; home="$dir/home"; mkdir -p "$home/state"
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"parent","label":"payments · primary"},{"workspace_id":"child","label":"└ invoice-check · p:AbCdEfGhIjKlMnOpQrStUv"}]}}'
    response "$dir" 2 '{"result":{"workspace":{"workspace_id":"parent","label":"payments · project"}}}'
    out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
      fmtest /srv/payments '' '' parent 'payments · primary') \
      || fail "v$version exact parent migration failed: $out"
    [ "$out" = parent ] || fail "v$version exact parent returned '$out'"
    calls=$(cat "$log")
    assert_contains "$calls" $'workspace\037rename\037parent\037payments · project' \
      "v$version did not migrate the exact old parent"
    assert_not_contains "$calls" $'rename\037child' "v$version fallback renamed its child"
  done

  dir="$TMP_ROOT/exact-secondmate-parent"; home="$dir/home"; mkdir -p "$home/state"
  printf 'research\n' > "$home/.fm-secondmate-home"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"parent","label":"research · second mate"},{"workspace_id":"child","label":"└ invoice-check · p:AbCdEfGhIjKlMnOpQrStUv"}]}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
    fmtest /srv/payments '' '' parent '') \
    || fail "second-mate child fallback could not select its exact stable parent"
  [ "$out" = parent ] || fail "second-mate exact parent returned '$out'"
  calls=$(cat "$log")
  assert_not_contains "$calls" $'workspace\037rename' \
    "second-mate exact parent was renamed during fallback"

  for layout in missing foreign duplicate; do
    dir="$TMP_ROOT/exact-parent-$layout"; home="$dir/home"; mkdir -p "$home/state"
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    case "$layout" in
      missing) response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"child","label":"└ invoice-check · p:AbCdEfGhIjKlMnOpQrStUv"}]}}' ;;
      foreign) response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"parent","label":"foreign"}]}}' ;;
      duplicate) response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"parent","label":"payments · primary"},{"workspace_id":"parent","label":"payments · primary"}]}}' ;;
    esac
    out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_workspace_ensure \
      fmtest /srv/payments '' '' parent 'payments · primary' 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$layout exact parent was accepted"
    calls=$(cat "$log")
    assert_not_contains "$calls" $'workspace\037create' "$layout exact parent refusal created a workspace"
    assert_not_contains "$calls" $'workspace\037rename' "$layout exact parent refusal renamed a workspace"
  done
  pass "Herdr spawn recovery: v2/v3 fallback uses only the exact journal parent"
}

# A real flat ship spawn keeps the shared session lock and exact response pane
# through task publication. An honest rename failure rolls back only that pane,
# launches no agent, leaves no live orphan, and permits the same id to retry.
test_real_flat_publication_failure_cleanup_retry() {
  local mode dir home project worktree id fake state log public marker before_meta
  local out status start calls failed_pane new_pane
  for mode in absent existing; do
    dir="$TMP_ROOT/full-flat-publication-$mode"
    home="$dir/home"; project="$dir/payments"; worktree="$dir/worktree"
    id="flat-publication-$mode-$$"
    make_project_and_worktree "$project" "$worktree" \
      || fail "could not create $mode flat-publication project fixture"
    make_worker_home "$home" "$id"
    fake=$(make_stateful_herdr "$dir")
    state="$dir/state.json"; log="$dir/herdr.log"
    public="$home/state/$id.meta"; marker="$dir/rename-failed"
    before_meta="$dir/meta.before"
    if [ "$mode" = existing ]; then
      run_real_worker_spawn "$id" "$home" "$project" "$worktree" "$fake" "$state" "$log" \
        > "$dir/seed.out" 2> "$dir/seed.err" \
        || fail "could not seed existing flat metadata: $(cat "$dir/seed.err")"
      cp "$public" "$before_meta"
    fi
    start=$(wc -l < "$log" | tr -d '[:space:]')
    out=$(run_real_worker_spawn "$id" "$home" "$project" "$worktree" "$fake" "$state" "$log" \
      "$public" "$marker" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$mode flat metadata rename failure reported spawn success"
    [ -s "$marker" ] || fail "$mode flat fault did not reach task metadata publication"
    failed_pane=$(cat "$marker")
    calls=$(sed -n "$((start + 1)),\$p" "$log")
    assert_contains "$calls" "pane"$'\037'"close"$'\037'"$failed_pane" \
      "$mode flat publication failure did not close its response-derived pane"
    assert_not_contains "$calls" $'pane\037send-text' \
      "$mode flat publication failure launched an agent"
    jq -e --arg label "$id · worker" \
      '([.panes[] | select(.label == $label)] | length) == 0' "$state" >/dev/null \
      || fail "$mode flat publication failure left a live task pane"
    if [ "$mode" = absent ]; then
      [ ! -e "$public" ] && [ ! -L "$public" ] \
        || fail "absent flat publication failure created public metadata"
    else
      cmp -s "$before_meta" "$public" \
        || fail "honest existing flat rename failure changed prior metadata"
    fi
    run_real_worker_spawn "$id" "$home" "$project" "$worktree" "$fake" "$state" "$log" \
      > "$dir/retry.out" 2> "$dir/retry.err" \
      || fail "$mode flat same-id retry failed: $(cat "$dir/retry.err")"
    new_pane=$(grep '^herdr_pane_id=' "$public" | cut -d= -f2-)
    [ -n "$new_pane" ] || fail "$mode flat retry omitted its published pane id"
    jq -e --arg pane "$new_pane" --arg label "$id · worker" '
      ([.panes[] | select(.pane_id == $pane and .label == $label)] | length) == 1
    ' "$state" >/dev/null || fail "$mode flat retry did not leave one published task pane"
  done
  pass "Herdr full spawn: flat metadata publication failure rolls back its exact pane and same-id retry succeeds"
}

make_secondmate_home() {  # <home> <id>
  mkdir -p "$1/bin" "$1/state" "$1/config" "$1/data" "$1/projects"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
  printf '# Safe temporary Firstmate second-mate fixture.\n' > "$1/AGENTS.md"
  printf 'Safe second-mate spawn fixture.\n' > "$1/data/charter.md"
}

run_real_secondmate_spawn() {  # <id> <primary-home> <child-home> <fakebin> <state> <log> [fail-path] [fail-marker] [unsafe-final-path] [unsafe-final-marker]
  local id=$1 primary=$2 child=$3 fake=$4 state=$5 log=$6 fail_path=${7:-} fail_marker=${8:-}
  local unsafe_final_path=${9:-} unsafe_final_marker=${10:-}
  track_task_tmp "$id"
  PATH="$fake:$BASE_PATH" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary" HERDR_SESSION=fmtest \
    FM_FAKE_HERDR_STATE="$state" FM_HERDR_LOG="$log" FM_FAKE_HERDR_WORKTREE="$child" \
    FM_TEST_FAIL_PUBLIC_PATH="$fail_path" FM_TEST_FAIL_MARKER="$fail_marker" \
    FM_TEST_UNSAFE_FINAL_PATH="$unsafe_final_path" FM_TEST_UNSAFE_FINAL_MARKER="$unsafe_final_marker" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$child" "sh -c 'true'" --secondmate --backend herdr
}

prepare_real_secondmate_publication_crash() {  # <dir> <case-suffix>
  local dir=$1 suffix=$2 out status
  SM_ID="sm-${suffix}-$$"
  SM_PRIMARY="$dir/primary-home"
  SM_CHILD="$dir/child-home"
  mkdir -p "$SM_PRIMARY/state" "$SM_PRIMARY/config" "$SM_PRIMARY/data"
  make_secondmate_home "$SM_CHILD" "$SM_ID"
  SM_FAKE=$(make_stateful_herdr "$dir")
  SM_STATE="$dir/state.json"
  SM_LOG="$dir/herdr.log"
  SM_PARENT="$SM_CHILD/state/.herdr-parent.meta"
  SM_PUBLIC="$SM_PRIMARY/state/$SM_ID.meta"
  SM_FAIL_MARKER="$dir/primary-publication-failed"
  out=$(run_real_secondmate_spawn "$SM_ID" "$SM_PRIMARY" "$SM_CHILD" \
    "$SM_FAKE" "$SM_STATE" "$SM_LOG" "$SM_PUBLIC" "$SM_FAIL_MARKER" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "$suffix first second-mate spawn did not stop at primary publication"
  [ -e "$SM_FAIL_MARKER" ] || fail "$suffix fault did not reach primary metadata publication"
  [ -f "$SM_PARENT" ] && [ ! -L "$SM_PARENT" ] \
    || fail "$suffix fault occurred before real child-home parent publication"
  [ ! -e "$SM_PUBLIC" ] && [ ! -L "$SM_PUBLIC" ] \
    || fail "$suffix fault unexpectedly published primary metadata"
  SM_OLD_WORKSPACE=$(grep '^herdr_workspace_id=' "$SM_PARENT" | cut -d= -f2-)
  SM_OLD_TAB=$(grep '^herdr_tab_id=' "$SM_PARENT" | cut -d= -f2-)
  SM_OLD_PANE=$(grep '^herdr_pane_id=' "$SM_PARENT" | cut -d= -f2-)
  [ -n "$SM_OLD_WORKSPACE" ] && [ -n "$SM_OLD_TAB" ] && [ -n "$SM_OLD_PANE" ] \
    || fail "$suffix parent publication omitted its exact tuple"
}

# Fault after the real child-home parent publication and before the primary
# publication, then retry the same full spawn. Only the exact one-pane,
# no-agent husk may be replaced, and both records must converge on the new tuple.
test_real_secondmate_publication_crash_retry() {
  local dir retry_start retry_calls new_tab new_pane
  dir="$TMP_ROOT/full-secondmate-retry"
  prepare_real_secondmate_publication_crash "$dir" retry
  retry_start=$(wc -l < "$SM_LOG" | tr -d '[:space:]')
  run_real_secondmate_spawn "$SM_ID" "$SM_PRIMARY" "$SM_CHILD" \
    "$SM_FAKE" "$SM_STATE" "$SM_LOG" > "$dir/retry.out" 2> "$dir/retry.err" \
    || fail "same real second-mate spawn did not recover its exact publication husk: $(cat "$dir/retry.err")"
  [ -f "$SM_PUBLIC" ] && [ -f "$SM_PARENT" ] \
    || fail "second-mate retry did not publish both complete records"
  new_tab=$(grep '^herdr_tab_id=' "$SM_PUBLIC" | cut -d= -f2-)
  new_pane=$(grep '^herdr_pane_id=' "$SM_PUBLIC" | cut -d= -f2-)
  [ "$new_tab" != "$SM_OLD_TAB" ] && [ "$new_pane" != "$SM_OLD_PANE" ] \
    || fail "second-mate retry reused the old publication husk tuple"
  [ "$(grep '^herdr_workspace_id=' "$SM_PUBLIC")" = "$(grep '^herdr_workspace_id=' "$SM_PARENT")" ] \
    && [ "$(grep '^herdr_tab_id=' "$SM_PUBLIC")" = "$(grep '^herdr_tab_id=' "$SM_PARENT")" ] \
    && [ "$(grep '^herdr_pane_id=' "$SM_PUBLIC")" = "$(grep '^herdr_pane_id=' "$SM_PARENT")" ] \
    || fail "second-mate retry published different primary and parent tuples"
  retry_calls=$(sed -n "$((retry_start + 1)),\$p" "$SM_LOG")
  assert_contains "$retry_calls" "tab"$'\037'"close"$'\037'"$SM_OLD_TAB" \
    "second-mate retry did not close only its exact old husk tab"
  assert_not_contains "$retry_calls" "pane"$'\037'"close"$'\037'"$SM_OLD_PANE" \
    "second-mate retry closed the old pane directly instead of its exact tab"
  jq -e --arg old "$SM_OLD_PANE" --arg new "$new_pane" '
    ([.panes[] | select(.pane_id == $old)] | length) == 0
    and ([.panes[] | select(.pane_id == $new)] | length) == 1
  ' "$SM_STATE" >/dev/null || fail "second-mate retry did not leave exactly the replacement pane"
  pass "Herdr full spawn: real second-mate parent-first publication fault recovers one exact husk"
}

# Fault the real child-home publisher into an unsafe final path after task-pane
# creation. The adapter must close only the response pane, launch nothing, and
# allow the same id after the unsafe path is removed.
test_real_secondmate_unsafe_parent_publication_retry() {
  local dir id primary child fake state log parent public marker out status calls failed_pane new_pane
  dir="$TMP_ROOT/full-secondmate-unsafe-parent"
  id="sm-unsafe-parent-$$"
  primary="$dir/primary-home"; child="$dir/child-home"
  mkdir -p "$primary/state" "$primary/config" "$primary/data"
  make_secondmate_home "$child" "$id"
  child=$(cd "$child" && pwd -P)
  fake=$(make_stateful_herdr "$dir")
  state="$dir/state.json"; log="$dir/herdr.log"
  parent="$child/state/.herdr-parent.meta"
  public="$primary/state/$id.meta"
  marker="$dir/unsafe-final"
  out=$(run_real_secondmate_spawn "$id" "$primary" "$child" "$fake" "$state" "$log" \
    '' '' "$parent" "$marker" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "unsafe parent publication reported second-mate spawn success"
  [ -s "$marker" ] || fail "unsafe parent fixture did not reach the real parent rename"
  failed_pane=$(cat "$marker")
  [ -d "$parent" ] && [ ! -L "$parent" ] \
    || fail "unsafe parent fixture did not leave its injected final directory"
  [ ! -e "$public" ] && [ ! -L "$public" ] \
    || fail "unsafe parent publication created primary task metadata"
  calls=$(cat "$log")
  assert_contains "$calls" "pane"$'\037'"close"$'\037'"$failed_pane" \
    "unsafe parent publication did not roll back its response-derived pane"
  assert_not_contains "$calls" $'pane\037send-text' \
    "unsafe parent publication launched an agent"
  jq -e --arg label "$id · second mate" \
    '([.panes[] | select(.label == $label)] | length) == 0' "$state" >/dev/null \
    || fail "unsafe parent publication left a live second-mate task pane"
  rmdir "$parent"
  run_real_secondmate_spawn "$id" "$primary" "$child" "$fake" "$state" "$log" \
    > "$dir/retry.out" 2> "$dir/retry.err" \
    || fail "unsafe parent same-id retry failed: $(cat "$dir/retry.err")"
  [ -f "$parent" ] && [ ! -L "$parent" ] && [ -f "$public" ] \
    || fail "unsafe parent retry did not publish both regular records"
  new_pane=$(grep '^herdr_pane_id=' "$public" | cut -d= -f2-)
  jq -e --arg pane "$new_pane" --arg label "$id · second mate" '
    ([.panes[] | select(.pane_id == $pane and .label == $label)] | length) == 1
  ' "$state" >/dev/null || fail "unsafe parent retry did not leave its one published pane"
  pass "Herdr full spawn: unsafe parent publication rolls back its exact pane and same-id retry succeeds"
}

# Recreate the same real parent-first fault, then disconfirm recovery rights for
# a live agent, wrong identity, symlink record, extra pane, and foreign
# same-label tab. Every retry must stop before create, rename, close, or launch.
test_real_secondmate_parent_recovery_disconfirming_cases() {
  local mode dir retry_start out status retry_calls mutations saved
  for mode in live-agent wrong-identity symlink extra-pane foreign-same-label; do
    dir="$TMP_ROOT/full-secondmate-$mode"
    prepare_real_secondmate_publication_crash "$dir" "${mode//-/_}"
    case "$mode" in
      live-agent)
        # shellcheck disable=SC2016  # jq variable, not shell expansion
        state_update "$SM_STATE" --arg pane "$SM_OLD_PANE" '.agents[$pane] = "idle"'
        ;;
      wrong-identity)
        perl -pi -e 's/^task_id=.*/task_id=foreign/' "$SM_PARENT"
        ;;
      symlink)
        saved="$dir/real-parent.meta"
        cp "$SM_PARENT" "$saved"
        rm -f "$SM_PARENT"
        ln -s "$saved" "$SM_PARENT"
        ;;
      extra-pane)
        # shellcheck disable=SC2016  # jq variables, not shell expansion
        state_update "$SM_STATE" --arg workspace "$SM_OLD_WORKSPACE" --arg tab "$SM_OLD_TAB" \
          --arg home "$SM_CHILD" '
          .panes += [{workspace_id:$workspace,tab_id:$tab,pane_id:"foreign:extra-pane",label:"foreign",cwd:$home,foreground_cwd:$home}]
        '
        ;;
      foreign-same-label)
        # shellcheck disable=SC2016  # jq variables, not shell expansion
        state_update "$SM_STATE" --arg workspace "$SM_OLD_WORKSPACE" --arg home "$SM_CHILD" \
          --arg label "$SM_ID · second mate" '
          .tabs += [{workspace_id:$workspace,tab_id:"foreign:same-label",label:$label,focused:false}]
          | .panes += [{workspace_id:$workspace,tab_id:"foreign:same-label",pane_id:"foreign:same-label-pane",label:$label,cwd:$home,foreground_cwd:$home}]
        '
        ;;
    esac
    retry_start=$(wc -l < "$SM_LOG" | tr -d '[:space:]')
    out=$(run_real_secondmate_spawn "$SM_ID" "$SM_PRIMARY" "$SM_CHILD" \
      "$SM_FAKE" "$SM_STATE" "$SM_LOG" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$mode second-mate parent recovery unexpectedly launched"
    [ ! -e "$SM_PUBLIC" ] && [ ! -L "$SM_PUBLIC" ] \
      || fail "$mode refusal published primary metadata"
    retry_calls=$(sed -n "$((retry_start + 1)),\$p" "$SM_LOG")
    mutations=$(printf '%s\n' "$retry_calls" | awk -F $'\037' '
      (($1 == "workspace" && ($2 == "create" || $2 == "rename")) ||
       ($1 == "tab" && ($2 == "create" || $2 == "rename" || $2 == "close")) ||
       ($1 == "pane" && ($2 == "rename" || $2 == "close" || $2 == "run"))) { print }
    ')
    [ -z "$mutations" ] || fail "$mode second-mate refusal mutated Herdr: $mutations"
    [ -n "$out" ] || fail "$mode second-mate refusal returned no diagnostic"
  done
  pass "Herdr full spawn: unsafe second-mate parent evidence refuses before mutation"
}

write_parent_record() {  # <home> <id> <workspace> <tab> <pane>
  local home=$1 id=$2 workspace=$3 tab=$4 pane=$5
  FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_parent_metadata_write "$1/state/.herdr-parent.meta" "$2" "$1" \
      fmtest "$3" "$4" "$5" "$2 · second mate" "$2 · second mate"
  ' "$ROOT" "$home" "$id" "$workspace" "$tab" "$pane"
}
write_secondmate_snapshot() {  # <dir> <first-call> <home> [agent-json] [pane-list]
  local dir=$1 first=$2 home=$3 agent=${4:-'{"error":{"code":"agent_not_found"}}'}
  local panes=${5:-'[{"workspace_id":"w1","pane_id":"w1:p1","tab_id":"w1:t1"}]'}
  response "$dir" "$first" '{"result":{"workspaces":[{"workspace_id":"w1","label":"research · second mate"}]}}'
  response "$dir" "$((first + 1))" '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"research · second mate"}]}}'
  response "$dir" "$((first + 2))" "{\"result\":{\"panes\":$panes}}"
  response "$dir" "$((first + 3))" "{\"result\":{\"pane\":{\"workspace_id\":\"w1\",\"tab_id\":\"w1:t1\",\"pane_id\":\"w1:p1\",\"label\":\"research · second mate\",\"cwd\":\"$home\"}}}"
  response "$dir" "$((first + 4))" "$agent"
}

# A child-home parent record recovers only one exact one-pane no-agent
# second-mate husk. The old tab closes only after two identical snapshots and
# the republished parent record carries the replacement tuple.
test_secondmate_parent_only_recovery() {
  local dir home parent log fake out calls agent panes status mode good_parent task_meta helper
  dir="$TMP_ROOT/secondmate-parent"; home="$dir/home"; mkdir -p "$home/state"
  printf 'research\n' > "$home/.fm-secondmate-home"
  parent="$home/state/.herdr-parent.meta"
  write_parent_record "$home" research w1 w1:t1 w1:p1 || fail "could not write parent recovery record"
  log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
  write_secondmate_snapshot "$dir" 1 "$home"
  response "$dir" 6 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"research · second mate"}]}}'
  response "$dir" 7 '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
  response "$dir" 8 '{"result":{"tab":{"workspace_id":"w1","tab_id":"w1:t2","label":"research · second mate"}}}'
  response "$dir" 9 '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p2","label":"research · second mate"}}}'
  write_secondmate_snapshot "$dir" 10 "$home"
  response "$dir" 15 '{}'
  response "$dir" 16 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t2","label":"research · second mate"}]}}'
  out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_create_task \
    fmtest:w1 research secondmate "$home" '' '' "$parent" "$parent") \
    || fail "parent-only second-mate recovery failed: $out"
  [ "$out" = 'w1:t2 w1:p2' ] || fail "parent-only recovery returned '$out'"
  [ "$(grep '^herdr_tab_id=' "$parent")" = herdr_tab_id=w1:t2 ] \
    && [ "$(grep '^herdr_pane_id=' "$parent")" = herdr_pane_id=w1:p2 ] \
    || fail "parent record did not republish the replacement tuple"
  calls=$(cat "$log")
  assert_contains "$calls" $'tab\037close\037w1:t1' "parent-only recovery did not close the exact old tab"
  assert_not_contains "$calls" $'pane\037close\037w1:p1' "parent-only recovery closed the old pane directly"

  task_meta="$dir/primary.meta"
  printf '%s\n' \
    'backend=herdr' 'kind=secondmate' "project=$home" "home=$home" "worktree=$home" \
    'herdr_session=fmtest' 'herdr_session_display_label=Shared Herdr session' \
    'herdr_workspace_id=w1' 'herdr_tab_id=w1:t2' 'herdr_pane_id=w1:p2' \
    'display_label=research · second mate' 'herdr_workspace_label=research · second mate' \
    'herdr_tab_label=research · second mate' 'herdr_pane_label=research · second mate' > "$task_meta"
  helper=$(sed -n '/^spawn_herdr_secondmate_publications_match()/,/^}/p' "$ROOT/bin/fm-spawn.sh")
  FM_TEST_HELPER="$helper" FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    eval "$FM_TEST_HELPER"
    spawn_herdr_secondmate_publications_match "$1" "$2" research "$3"
  ' "$ROOT" "$task_meta" "$parent" "$home" \
    || fail "matching second-mate parent and primary publications were refused"
  perl -pi -e 's/^herdr_pane_id=.*/herdr_pane_id=foreign:pane/' "$task_meta"
  if FM_TEST_HELPER="$helper" FM_HOME="$home" bash -c '
    . "$0/bin/backends/herdr.sh"
    eval "$FM_TEST_HELPER"
    spawn_herdr_secondmate_publications_match "$1" "$2" research "$3"
  ' "$ROOT" "$task_meta" "$parent" "$home" >/dev/null 2>&1; then
    fail "mismatched second-mate parent and primary tuples were accepted"
  fi

  for mode in live-agent extra-pane foreign-tab missing-workspace missing-tab missing-pane; do
    dir="$TMP_ROOT/secondmate-$mode"; home="$dir/home"; mkdir -p "$home/state"
    printf 'research\n' > "$home/.fm-secondmate-home"
    parent="$home/state/.herdr-parent.meta"
    write_parent_record "$home" research w1 w1:t1 w1:p1 || fail "could not write $mode parent record"
    log="$dir/log"; : > "$log"; fake=$(make_fake_herdr "$dir")
    agent='{"error":{"code":"agent_not_found"}}'
    panes='[{"workspace_id":"w1","pane_id":"w1:p1","tab_id":"w1:t1"}]'
    [ "$mode" != live-agent ] || agent='{"result":{"agent":{"agent_status":"idle"}}}'
    [ "$mode" != extra-pane ] || panes='[{"workspace_id":"w1","pane_id":"w1:p1","tab_id":"w1:t1"},{"workspace_id":"w1","pane_id":"w1:p9","tab_id":"w1:t1"}]'
    case "$mode" in
      missing-workspace)
        response "$dir" 1 '{"result":{"workspaces":[]}}'
        response "$dir" 2 '{"result":{"tabs":[]}}'
        response "$dir" 3 '{"error":{"code":"pane_not_found"}}'
        ;;
      missing-tab)
        response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"research · second mate"}]}}'
        response "$dir" 2 '{"result":{"tabs":[]}}'
        response "$dir" 3 '{"error":{"code":"pane_not_found"}}'
        ;;
      missing-pane)
        response "$dir" 1 '{"result":{"workspaces":[{"workspace_id":"w1","label":"research · second mate"}]}}'
        response "$dir" 2 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"research · second mate"}]}}'
        response "$dir" 3 '{"result":{"panes":[]}}'
        response "$dir" 4 '{"error":{"code":"pane_not_found"}}'
        ;;
      *) write_secondmate_snapshot "$dir" 1 "$home" "$agent" "$panes" ;;
    esac
    if [ "$mode" = foreign-tab ]; then
      response "$dir" 6 '{"result":{"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","label":"research · second mate"},{"workspace_id":"w1","tab_id":"foreign","label":"research · second mate"}]}}'
    fi
    out=$(run_adapter "$home" "$fake" "$log" fm_backend_herdr_create_task \
      fmtest:w1 research secondmate "$home" '' '' "$parent" "$parent" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$mode second-mate parent recovery was accepted"
    calls=$(cat "$log")
    assert_not_contains "$calls" $'tab\037create' "$mode refusal created a replacement"
    assert_not_contains "$calls" $'tab\037close' "$mode refusal closed the old tab"
  done

  dir="$TMP_ROOT/parent-validator"; home="$dir/home"; mkdir -p "$home/state"
  printf 'research\n' > "$home/.fm-secondmate-home"
  parent="$home/state/.herdr-parent.meta"
  write_parent_record "$home" research w1 w1:t1 w1:p1 || fail "could not write validator parent record"
  good_parent="$dir/good-parent"; cp "$parent" "$good_parent"
  for mode in task marker kind home project worktree session label symlink; do
    rm -f "$parent"; cp "$good_parent" "$parent"
    case "$mode" in
      task) perl -pi -e 's/^task_id=.*/task_id=other/' "$parent" ;;
      marker) printf 'other\n' > "$home/.fm-secondmate-home" ;;
      kind) perl -pi -e 's/^kind=.*/kind=ship/' "$parent" ;;
      home) perl -pi -e 's#^home=.*#home=/foreign#' "$parent" ;;
      project) perl -pi -e 's#^project=.*#project=/foreign#' "$parent" ;;
      worktree) perl -pi -e 's#^worktree=.*#worktree=/foreign#' "$parent" ;;
      session) perl -pi -e 's/^herdr_session=.*/herdr_session=other/' "$parent" ;;
      label) perl -pi -e 's/^herdr_tab_label=.*/herdr_tab_label=foreign/' "$parent" ;;
      symlink) rm -f "$parent"; ln -s "$good_parent" "$parent" ;;
    esac
    if FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_parent_metadata_validate_recovery "$1" research "$2" "$2" "$2" fmtest' \
      "$ROOT" "$parent" "$home" >/dev/null 2>&1; then
      fail "$mode parent recovery record was accepted"
    fi
    printf 'research\n' > "$home/.fm-secondmate-home"
  done
  pass "Herdr spawn recovery: parent-only second mate replaces one exact no-agent husk"
}

# The spawn-owned classifier passes only proved prior-flat metadata onward and
# keeps projected child metadata as an explicit exclusion.
test_flat_retry_evidence_classification() {
  local dir home journal meta helper out token child HERDR_SES
  dir="$TMP_ROOT/flat-evidence"; home="$dir/home"; mkdir -p "$home/state"
  home=$(cd "$home" && pwd -P)
  HERDR_SES=fmtest
  export HERDR_SES
  token=AbCdEfGhIjKlMnOpQrStUv
  child="└ invoice-check · p:$token"
  helper=$(printf '%s\n' \
    "fm_backend_of_meta() { grep \"^backend=\" \"\$1\" 2>/dev/null | tail -1 | cut -d= -f2-; }"; \
    sed -n '/^herdr_projection_prepare_flat_evidence()/,/^}/p' "$ROOT/bin/fm-spawn.sh")
  journal="$home/state/invoice-check.herdr-presentation"
  printf '%s\n' \
    'version=2' 'task_id=invoice-check' "projection_id=$token" "home=$home" \
    'session=fmtest' 'workspace_id=child' 'tab_id=child:t1' 'pane_id=child:p1' \
    'parent_workspace_id=parent' 'parent_label=payments · primary' \
    "workspace_label=$child" 'task_label=fm-invoice-check' > "$journal"
  meta="$home/state/invoice-check.meta"
  write_task_meta "$meta" /srv/payments child child:t1 child:p1 "$child"
  out=$(FM_TEST_HELPER="$helper" FM_HOME="$home" FM_TEST_JOURNAL="$journal" FM_TEST_META="$meta" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      eval "$FM_TEST_HELPER"
      ID=invoice-check; HERDR_LABEL_HOME=$FM_HOME; PROJ_ABS=/srv/payments
      HERDR_HOME_LABEL="payments · project"
      herdr_projection_prepare_flat_evidence "$FM_TEST_JOURNAL" "$FM_TEST_META" || exit 1
      printf "%s|%s|%s|%s" "$HERDR_FLAT_TASK_META" "$HERDR_FLAT_EXCLUDED_META" \
        "$HERDR_FLAT_PARENT_WORKSPACE_ID" "$HERDR_FLAT_PARENT_PRIOR_LABEL"
    ' "$ROOT") || fail "v2 projected-child evidence classification failed"
  [ "$out" = "|$meta|parent|payments · primary" ] \
    || fail "v2 projected child was not excluded exactly: $out"
  perl -pi -e 's/^session=fmtest$/session=foreign/' "$journal"
  if FM_TEST_HELPER="$helper" FM_HOME="$home" FM_TEST_JOURNAL="$journal" FM_TEST_META="$meta" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      eval "$FM_TEST_HELPER"
      ID=invoice-check; HERDR_LABEL_HOME=$FM_HOME; PROJ_ABS=/srv/payments
      HERDR_HOME_LABEL="payments · project"
      herdr_projection_prepare_flat_evidence "$FM_TEST_JOURNAL" "$FM_TEST_META"
    ' "$ROOT" >/dev/null 2>&1; then
    fail "foreign v2 journal session granted flat-parent selection"
  fi
  perl -pi -e 's/^session=foreign$/session=fmtest/' "$journal"

  write_task_meta "$meta" /srv/payments parent parent:t1 parent:p1 'payments · project'
  out=$(FM_TEST_HELPER="$helper" FM_HOME="$home" FM_TEST_JOURNAL="$journal" FM_TEST_META="$meta" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      eval "$FM_TEST_HELPER"
      ID=invoice-check; HERDR_LABEL_HOME=$FM_HOME; PROJ_ABS=/srv/payments
      HERDR_HOME_LABEL="payments · project"
      herdr_projection_prepare_flat_evidence "$FM_TEST_JOURNAL" "$FM_TEST_META" || exit 1
      printf "%s|%s" "$HERDR_FLAT_TASK_META" "$HERDR_FLAT_EXCLUDED_META"
    ' "$ROOT") || fail "v2 prior-flat evidence classification failed"
  [ "$out" = "$meta|" ] || fail "v2 prior flat metadata lost exact-husk recovery: $out"

  printf '%s\n' 'version=1' 'task_id=invoice-check' "projection_id=$token" > "$journal"
  out=$(FM_TEST_HELPER="$helper" FM_HOME="$home" FM_TEST_JOURNAL="$journal" FM_TEST_META="$meta" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      eval "$FM_TEST_HELPER"
      ID=invoice-check; HERDR_LABEL_HOME=$FM_HOME; PROJ_ABS=/srv/payments
      HERDR_HOME_LABEL="payments · project"
      FM_BACKEND_HERDR_PROJECTION_TOKEN_MATCH_COUNT=1
      FM_BACKEND_HERDR_PROJECTION_UNIQUE_TOKEN_WORKSPACE_ID=child
      herdr_projection_prepare_flat_evidence "$FM_TEST_JOURNAL" "$FM_TEST_META" || exit 1
      printf "%s|%s" "$HERDR_FLAT_TASK_META" "$HERDR_FLAT_EXCLUDED_META"
    ' "$ROOT") || fail "v1 prior-flat evidence classification failed"
  [ "$out" = "$meta|" ] || fail "v1 prior flat metadata lost unique-child recovery: $out"
  pass "Herdr spawn recovery: projected and prior-flat metadata stay distinct"
}

# Keep the two evidence channels and publication order explicit in the real
# spawn owner. These assertions supplement the behavioral adapter fixtures.
test_spawn_wiring_keeps_recovery_channels_separate() {
  local source guide verification
  source=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$source" 'herdr_projection_prepare_flat_evidence' \
    "spawn has no projected-versus-flat evidence classifier"
  assert_contains "$source" "\"\$HERDR_FLAT_EXCLUDED_META\"" \
    "spawn does not pass projected metadata as an explicit exclusion"
  assert_contains "$source" "\"\$HERDR_PARENT_RECOVERY_META\"" \
    "spawn does not pass parent recovery separately from task metadata"
  assert_contains "$source" 'spawn_herdr_secondmate_publications_match' \
    "spawn does not compare parent and primary tuples before launch"
  guide=$(cat "$ROOT/docs/herdr-backend.md")
  verification=$(cat "$ROOT/docs/verification/runtime-backends.md")
  # shellcheck disable=SC2016  # Literal maintained Markdown, not shell expansion.
  assert_not_contains "$guide" 'The normal `fm-<id>` task tab' \
    "Herdr guide restored the stale normal-task label"
  assert_not_contains "$guide" 'The per-home workspace is reused' \
    "Herdr guide restored stale primary-project per-home wording"
  assert_not_contains "$guide" 'cross-home version 2 binding,' \
    "Herdr guide restored version-2-only cross-home refusal wording"
  assert_contains "$guide" 'The ordinary readable-role task tab' \
    "Herdr guide omitted the current ordinary task-label wording"
  assert_contains "$verification" \
    'ok - Herdr metadata: complete-schema atomic publication refuses unsafe and unverifiable public paths' \
    "runtime verification does not quote the current publisher test output"
  assert_not_contains "$verification" \
    'ok - Herdr metadata: concurrent visibility is complete-record-or-old across validation and rename failures' \
    "runtime verification restored output that no current test emits"
  pass "Herdr spawn recovery: flat, task, and parent evidence channels remain separate"
}

test_real_spawn_keeps_native_primary_and_firstmate_project_distinct
test_real_spawn_projection_fallback_and_reclaim_refusals
test_real_spawn_exact_journal_parent_refusals
test_real_flat_publication_failure_cleanup_retry
test_real_secondmate_publication_crash_retry
test_real_secondmate_unsafe_parent_publication_retry
test_real_secondmate_parent_recovery_disconfirming_cases
test_v1_flat_fallback_excludes_projected_child
test_v2_v3_flat_fallback_uses_exact_parent
test_secondmate_parent_only_recovery
test_flat_retry_evidence_classification
test_spawn_wiring_keeps_recovery_channels_separate
