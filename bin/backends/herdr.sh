#!/usr/bin/env bash
# bin/backends/herdr.sh - the herdr session-provider adapter (EXPERIMENTAL).
#
# Design: data/fm-backend-design-d7/herdr-addendum.md ("Interface mapping",
# decisions D1-D6) and the empirical verification recorded in
# data/fm-backend-design-d7/herdr-verification-p2.md (real herdr v0.7.1,
# protocol 14, macOS aarch64), refined by docs/herdr-backend.md's
# "workspace-per-home" pass (AGENTS.md task herdr-sm-spaces-k4). Herdr is a
# session provider ONLY (D3): the worktree provider stays treehouse, exactly
# like tmux. Sourced only through bin/fm-backend.sh's fm_backend_source in
# normal operation; the unit tests source it directly, so the FM_HOME fallback
# below keeps that path sane without fm-backend.sh's preamble.
#
# Default container shape (D4, decided empirically - see
# herdr-verification-p2.md "Task container shape", refined by
# docs/herdr-backend.md "Default task container shape"): one exact readable
# workspace per canonical project in the primary home, one stable marked
# workspace for each second-mate home, and one Herdr tab per task. An optional,
# default-off presentation flag creates a disposable workspace for a clean
# fresh task instead. That
# workspace is a non-authoritative visual projection containing only the normal
# task pane. Its random token and mutable label never authorize lookup,
# adoption, reuse, closure, deletion, task ownership, or endpoint selection.
# A version 2 or 3 journal can participate in replacing only its exact same-identity
# endpoint after metadata, home, session, workspace, tab, pane, parent, shape,
# focus, and agent-absence checks all agree under the session lock.
# Every ambiguous recovered launch uses the default flat home workspace when
# duplicate-agent risk is independently absent.
# Target resolution stays parallel to the tmux adapter in both layouts.
# Projected create, move, and cleanup operations capture the named session's
# exact active workspace and tab. Herdr 0.7.4's last-pane close can focus an
# unrelated neighbor, so projected cleanup serializes and restores only the
# exact pre-close tab id, while refusing to close the active tab itself.
#
# Target string shape: "<herdr-session>:<pane-id>", e.g. "default:w1:p2" (the
# pane id itself contains a colon; the session is always the FIRST field, the
# remainder is the whole pane id - fm_backend_herdr_parse_target splits on the
# first colon only). This is the value stored in a herdr task's meta window=
# field and is what fm_backend_resolve_selector already returns unchanged for
# exact task-id, legacy fm-<id>, and explicit backend-target forms (that
# function has no herdr-specific logic; it just returns meta's window=
# verbatim).
#
# Authoritative task recovery uses complete home-local metadata identities and
# corroborates every session/workspace/tab/pane tuple against live Herdr state:
# fm_backend_herdr_list_live. Display labels never select a parent or task
# endpoint. The presentation journal is deliberately excluded from that path.
#
# Requires: herdr (CLI + socket), jq (JSON parsing). Bootstrap detects these
# through fm_backend_required_tools only when herdr is the resolved backend;
# this adapter also gates them again before spawning.

# FM_HOME fallback: every real caller (fm-spawn.sh, fm-peek.sh, fm-send.sh,
# fm-teardown.sh, fm-watch.sh, fm-crew-state.sh) already sets FM_HOME as a
# global before sourcing fm-backend.sh (which sources this file), so this
# never overrides a real invocation. It exists only so this file's own unit
# tests, which source it directly without that preamble, resolve to a sane
# default (the firstmate repo root - never a secondmate home, so
# fm_backend_herdr_workspace_label falls through to "firstmate" exactly like
# pre-P3 behavior when a test does not care about home-specific labeling).
FM_BACKEND_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_HERDR_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-composer-lib.sh"

# Shared, backend-neutral normalized-transition shape and the single-owner
# status->action policy table (bin/fm-transition-lib.sh). This adapter's event
# subscriber (fm_backend_herdr_wait_transition) normalizes every
# pane.agent_status_changed edge through fm_transition_record and routes it
# through fm_transition_policy - it never re-encodes the mapping.
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-transition-lib.sh"

FM_BACKEND_HERDR_MIN_PROTOCOL=14
# events.subscribe (the native pane.agent_status_changed push stream) and its
# subscription_event schema first shipped at protocol 16 (verified: herdr
# 0.7.3). Below this, or with the events surface absent from `herdr api schema`,
# the event fast-path fails closed to the watcher's poll loop
# (fm_backend_herdr_events_capable). Distinct from FM_BACKEND_HERDR_MIN_PROTOCOL
# (14): the adapter's spawn/capture/send primitives work on 14, only the push
# subscriber needs 16.
FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL=16
# workspace.move first appears in the protocol-16 schema.
# The installed CLI does not expose it as a workspace subcommand, so the
# presentation path uses one narrowly whitelisted raw-socket request after
# verifying the exact method and parameter schema.
FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL=16
# Per-pane escalation dedupe marker prefix, under the state dir. One marker per
# window (keyed like the watcher's own .stale-<key>): set when a ->blocked edge
# is enqueued, cleared on any working edge, so exactly one wake fires per
# ->blocked edge and a reconnect level-reconcile never re-delivers a still-
# blocked pane. Mirrors bin/fm-watch.sh's .stale-<key> naming.
FM_BACKEND_HERDR_ESCALATED_PREFIX=".herdr-escalated-"
# .fm-secondmate-home is written by bin/fm-home-seed.sh (AGENTS.md section 6)
# at a seeded secondmate home's root, containing exactly that secondmate's id.
# The primary firstmate home never carries this marker.
FM_BACKEND_HERDR_SECONDMATE_MARKER=".fm-secondmate-home"
# The default-off presentation projection is intentionally separate from the
# authoritative task endpoint record.
# A per-task journal lives under state/ as <id>.herdr-presentation.
# Version 1 records only the attempted projection's random correlator.
# Version 2 additionally binds the successful projection's exact home,
# session, workspace, tab, pane, parent, and legacy presentation labels.
# Version 3 adds the task kind and requires the adapter-derived readable task
# label so a resumed spawn can replace one verified agent-free husk under the
# session lock. No send, capture, Treehouse, or general task-ownership path
# reads it.
FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX=".herdr-presentation"
# A scout-to-ship promotion spans two live labels, one metadata record, and an
# optional presentation binding. The exact-ID intent makes that forward-only
# transaction recoverable without granting label-selected mutation authority.
FM_BACKEND_HERDR_ROLE_TRANSITION_SUFFIX=".herdr-role-transition"

# The adapter alone formats concise semantic labels; exact IDs only route.
FM_BACKEND_HERDR_LABEL_SEPARATOR=' · '
FM_BACKEND_HERDR_LABEL_MAX_SUBJECT=48
# Herdr 0.7.4 has no native-session rename operation, and one running session
# may carry several Firstmate homes and unrelated workspaces. This concise alias
# is presentation data only; the named session remains the sole routing key.
FM_BACKEND_HERDR_SESSION_DISPLAY_LABEL='Shared Herdr session'

fm_backend_herdr_session_display_label() {
  printf '%s' "$FM_BACKEND_HERDR_SESSION_DISPLAY_LABEL"
}

fm_backend_herdr_role_for_kind() {  # <task-kind>
  case "$1" in
    ship) printf 'worker' ;;
    scout) printf 'scout' ;;
    secondmate) printf 'second mate' ;;
    *) echo "error: invalid task kind for herdr readable label: $1" >&2; return 1 ;;
  esac
}

fm_backend_herdr_format_label() {  # <concise-subject> <role>
  local subject=${1:-} role=${2:-}
  case "$role" in primary|project|worker|scout|'second mate') ;; *) return 1 ;; esac
  if [ "$role" = primary ]; then
    [ "$subject" = firstmate ] || {
      echo "error: the herdr primary role is reserved for the native firstmate tuple" >&2
      return 1
    }
  elif [ "$subject" = firstmate ] && [ "$role" != project ]; then
    echo "error: herdr readable-label subject 'firstmate' is reserved for native primary or project roles" >&2
    return 1
  fi
  if [ "$subject" != firstmate ]; then
    case "$subject" in
      ''|fm-*|2ndmate-*|primary|worker|scout|secondmate|'second mate'|task|project|workspace|tab|pane|unknown|default|untitled|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*|*[!A-Za-z0-9])
        echo "error: invalid herdr readable-label subject: $subject" >&2
        return 1
        ;;
    esac
  fi
  [ "${#subject}" -le "$FM_BACKEND_HERDR_LABEL_MAX_SUBJECT" ] || {
    echo "error: herdr readable-label subject exceeds $FM_BACKEND_HERDR_LABEL_MAX_SUBJECT characters" >&2
    return 1
  }
  printf '%s%s%s' "$subject" "$FM_BACKEND_HERDR_LABEL_SEPARATOR" "$role"
}

fm_backend_herdr_secondmate_subject() {
  local marker="$FM_HOME/$FM_BACKEND_HERDR_SECONDMATE_MARKER" subject extra
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  # shellcheck disable=SC2034  # the second read exists only to reject a second line
  { IFS= read -r subject && ! IFS= read -r extra; } < "$marker" || return 1
  fm_backend_herdr_format_label "$subject" 'second mate' >/dev/null || return 1
  printf '%s' "$subject"
}

fm_backend_herdr_workspace_label() {  # <spawned-project-or-home>
  local project=${1:-} subject marker="$FM_HOME/$FM_BACKEND_HERDR_SECONDMATE_MARKER"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    subject=$(fm_backend_herdr_secondmate_subject) || {
      echo "error: invalid stable second-mate marker for herdr workspace label" >&2
      return 1
    }
    fm_backend_herdr_format_label "$subject" 'second mate'
    return
  fi
  subject=${project%/}; subject=${subject##*/}
  fm_backend_herdr_format_label "$subject" project
}

# Before project workspaces gained their own role, a primary-home task
# container used <project> · primary. Only an exact metadata or journal tuple
# may corroborate this prior spelling; native firstmate · primary remains a
# separate process-owned tuple and is never published as task ownership.
fm_backend_herdr_workspace_prior_primary_label() {  # <spawned-project>
  local project=${1:-} subject project_label
  [ ! -e "$FM_HOME/$FM_BACKEND_HERDR_SECONDMATE_MARKER" ] \
    && [ ! -L "$FM_HOME/$FM_BACKEND_HERDR_SECONDMATE_MARKER" ] || return 1
  subject=${project%/}; subject=${subject##*/}
  project_label=$(fm_backend_herdr_format_label "$subject" project) || return 1
  printf '%s%sprimary' "${project_label%"${FM_BACKEND_HERDR_LABEL_SEPARATOR}"project}" \
    "$FM_BACKEND_HERDR_LABEL_SEPARATOR"
}

fm_backend_herdr_task_label() {  # <task-id> <task-kind>
  local subject=$1 kind=$2 role
  role=$(fm_backend_herdr_role_for_kind "$kind") || return 1
  [ "$kind" != secondmate ] || subject=$(fm_backend_herdr_secondmate_subject) || {
    echo "error: invalid stable second-mate marker for herdr task label" >&2
    return 1
  }
  fm_backend_herdr_format_label "$subject" "$role"
}

# fm_backend_herdr_cli: run `herdr <args...>` scoped to <session>, setting
# BOTH the HERDR_SESSION env var AND appending a trailing `--session <name>`
# CLI flag. Verified empirically (docs/herdr-backend.md "Session targeting: the
# --session flag, not HERDR_SESSION alone"): on the installed herdr 0.7.1
# client, the HERDR_SESSION env var is NOT reliably honored by CLI subcommands
# once ANY other herdr server is already bound on the machine - queries
# silently fall back to whatever server IS running (the wrong one) instead of
# routing to the requested session or refusing. The `--session <name>` global
# flag (verified in both leading and trailing position; trailing used here to
# keep every call site a minimal, append-only diff) always routes correctly,
# including starting a genuinely separate, isolated server process. The env
# var is kept alongside it - harmless, self-documenting, and forward-
# compatible if a future herdr build honors it. Never used by
# fm_backend_herdr_version_check, which is intentionally session-independent
# (reads only .client.* fields).
fm_backend_herdr_cli() {  # <session> <herdr-subcommand-and-args...>
  local session=$1
  shift
  HERDR_SESSION="$session" herdr "$@" --session "$session"
}

# fm_backend_herdr_tool_check: refuse loudly if herdr or jq is missing.
fm_backend_herdr_tool_check() {
  command -v herdr >/dev/null 2>&1 || { echo "error: backend=herdr selected but the 'herdr' CLI is not installed (https://herdr.dev) (dual-licensed AGPL-3.0-or-later/commercial)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=herdr selected but 'jq' is not installed (required to parse herdr's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_herdr_version_check: refuse loudly on a missing/incompatible
# herdr client. Verified locally: v0.7.1, protocol 14 (herdr status --json's
# .client.protocol; client info is session-independent, unlike .server).
fm_backend_herdr_version_check() {
  fm_backend_herdr_tool_check || return 1
  local status protocol version
  status=$(herdr status --json 2>/dev/null) || { echo "error: 'herdr status --json' failed; is herdr installed correctly?" >&2; return 1; }
  protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null)
  version=$(printf '%s' "$status" | jq -r '.client.version // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "error: could not read herdr client protocol from 'herdr status --json'; refusing to use an unverified herdr build" >&2
      return 1
      ;;
  esac
  if [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_PROTOCOL" ]; then
    echo "error: herdr protocol $protocol (version ${version:-unknown}) is older than the verified minimum $FM_BACKEND_HERDR_MIN_PROTOCOL; update herdr (herdr update) before using backend=herdr" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_session: resolve which named herdr session this normal
# spawn/op uses. HERDR_SESSION mirrors tmux's $TMUX ambient-selection for
# adapter workspace/tab/pane operations: an operator (or firstmate's own
# isolated test harness) sets it explicitly; absent means herdr's own
# "default" session. Do not use HERDR_SESSION alone for destructive test
# cleanup; tests/herdr-test-safety.sh documents and guards that path.
fm_backend_herdr_session() {
  printf '%s' "${HERDR_SESSION:-default}"
}

# fm_backend_herdr_projection_id: generate a compact 128-bit base64url token.
# The token is a non-adversarial visual correlator, never destructive
# authority.
fm_backend_herdr_projection_id() {
  local token
  token=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null \
    | base64 \
    | tr '+/' '-_' \
    | tr -d '=\r\n') || return 1
  [ "${#token}" -eq 22 ] || return 1
  case "$token" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s' "$token"
}

fm_backend_herdr_projection_journal_path() {  # <state-dir> <task-id>
  printf '%s/%s%s' "$1" "$2" "$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"
}

# fm_backend_herdr_projection_journal_create: atomically publish the
# non-authoritative attempt journal before any projection workspace create.
# A hard-link publication in the same state directory gives create-if-absent
# semantics, so concurrent attempts cannot overwrite each other's token.
fm_backend_herdr_projection_journal_create() {  # <state-dir> <task-id>
  local state=$1 id=$2 journal token tmp
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*)
      echo "error: invalid task id for herdr presentation journal" >&2
      return 1
      ;;
  esac
  mkdir -p "$state" || return 1
  journal=$(fm_backend_herdr_projection_journal_path "$state" "$id")
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    echo "error: herdr presentation journal already exists for $id; refusing a concurrent or repeated projected create" >&2
    return 1
  fi
  token=$(fm_backend_herdr_projection_id) || {
    echo "error: could not generate a 128-bit herdr presentation projection id" >&2
    return 1
  }
  tmp=$(mktemp "$state/.${id}.herdr-presentation.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! ln "$tmp" "$journal" 2>/dev/null; then
    rm -f "$tmp"
    echo "error: herdr presentation journal appeared concurrently for $id; refusing projected create" >&2
    return 1
  fi
  rm -f "$tmp"
  printf '%s' "$token"
}

fm_backend_herdr_projection_journal_field() {  # <journal> <key>
  local journal=$1 key=$2 count
  count=$(grep -c "^${key}=" "$journal" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$journal" 2>/dev/null | cut -d= -f2-
}

# fm_backend_herdr_projection_journal_snapshot: validate a version 1 attempt,
# version 2 legacy exact binding, or version 3 readable-label exact binding
# without sourcing shell code. FORMAT_VERSION is the exact on-disk version.
# VERSION remains the binding compatibility class consumed by the unchanged
# session-cleanup reader, where both version 2 and version 3 require the same
# exact home/session/endpoint tuple checks.
fm_backend_herdr_projection_journal_snapshot() {  # <journal> <task-id>
  local journal=$1 id=$2 lines expected_label expected_task_label exact
  FM_BACKEND_HERDR_JOURNAL_VERSION=""
  FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION=""
  FM_BACKEND_HERDR_JOURNAL_TASK_ID=""
  FM_BACKEND_HERDR_JOURNAL_TASK_KIND=""
  FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID=""
  FM_BACKEND_HERDR_JOURNAL_HOME=""
  FM_BACKEND_HERDR_JOURNAL_SESSION=""
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID=""
  FM_BACKEND_HERDR_JOURNAL_TAB_ID=""
  FM_BACKEND_HERDR_JOURNAL_PANE_ID=""
  FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID=""
  FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL=""
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL=""
  FM_BACKEND_HERDR_JOURNAL_TASK_LABEL=""
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  lines=$(wc -l < "$journal" 2>/dev/null | tr -d '[:space:]')
  FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION=$(fm_backend_herdr_projection_journal_field "$journal" version) || return 1
  FM_BACKEND_HERDR_JOURNAL_VERSION=$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION
  FM_BACKEND_HERDR_JOURNAL_TASK_ID=$(fm_backend_herdr_projection_journal_field "$journal" task_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID=$(fm_backend_herdr_projection_journal_field "$journal" projection_id) || return 1
  [ "$FM_BACKEND_HERDR_JOURNAL_TASK_ID" = "$id" ] || return 1
  [ "${#FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID}" -eq 22 ] || return 1
  case "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  case "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION:$lines" in
    1:3) return 0 ;;
    2:12) ;;
    3:13)
      # shellcheck disable=SC2034  # unchanged session-cleanup reader consumes this compatibility class
      FM_BACKEND_HERDR_JOURNAL_VERSION=2
      FM_BACKEND_HERDR_JOURNAL_TASK_KIND=$(fm_backend_herdr_projection_journal_field "$journal" task_kind) || return 1
      case "$FM_BACKEND_HERDR_JOURNAL_TASK_KIND" in ship|scout) ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  FM_BACKEND_HERDR_JOURNAL_HOME=$(fm_backend_herdr_projection_journal_field "$journal" home) || return 1
  FM_BACKEND_HERDR_JOURNAL_SESSION=$(fm_backend_herdr_projection_journal_field "$journal" session) || return 1
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID=$(fm_backend_herdr_projection_journal_field "$journal" workspace_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_TAB_ID=$(fm_backend_herdr_projection_journal_field "$journal" tab_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PANE_ID=$(fm_backend_herdr_projection_journal_field "$journal" pane_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID=$(fm_backend_herdr_projection_journal_field "$journal" parent_workspace_id) || return 1
  FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL=$(fm_backend_herdr_projection_journal_field "$journal" parent_label) || return 1
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL=$(fm_backend_herdr_projection_journal_field "$journal" workspace_label) || return 1
  FM_BACKEND_HERDR_JOURNAL_TASK_LABEL=$(fm_backend_herdr_projection_journal_field "$journal" task_label) || return 1
  case "$FM_BACKEND_HERDR_JOURNAL_HOME" in
    /*) ;;
    *) return 1 ;;
  esac
  for exact in \
    "$FM_BACKEND_HERDR_JOURNAL_SESSION" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID"; do
    case "$exact" in
      ''|*[[:space:]]*) return 1 ;;
    esac
  done
  [ -n "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" ] \
    && [ -n "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" ] \
    && [ -n "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" ] || return 1
  expected_label=$(fm_backend_herdr_projection_workspace_label "$id" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID")
  if [ "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION" = 2 ]; then
    expected_task_label="fm-$id"
  else
    expected_task_label=$(FM_HOME="$FM_BACKEND_HERDR_JOURNAL_HOME" \
      fm_backend_herdr_task_label "$id" "$FM_BACKEND_HERDR_JOURNAL_TASK_KIND") || return 1
  fi
  [ "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" = "$expected_label" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" = "$expected_task_label" ]
}

# fm_backend_herdr_projection_journal_token: validate and read either journal
# version's non-authoritative visual correlator.
fm_backend_herdr_projection_journal_token() {  # <journal> <task-id>
  fm_backend_herdr_projection_journal_snapshot "$1" "$2" || return 1
  printf '%s' "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID"
}

fm_backend_herdr_projection_home_identity() {  # <home>
  local home=$1
  [ -d "$home" ] || return 1
  (cd "$home" 2>/dev/null && pwd -P)
}

fm_backend_herdr_projection_journal_write_v2() {  # <journal> <task-id> <token> <home> <session> <workspace> <tab> <pane> <parent-workspace> <parent-label> <workspace-label> <task-label>
  local journal=$1 id=$2 token=$3 home=$4 session=$5 workspace=$6 tab=$7 pane=$8
  local parent_workspace=$9 parent_label=${10} workspace_label=${11} task_label=${12} state tmp
  state=$(dirname "$journal")
  tmp=$(mktemp "$state/.${id}.herdr-presentation.bind.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
    printf 'home=%s\n' "$home"
    printf 'session=%s\n' "$session"
    printf 'workspace_id=%s\n' "$workspace"
    printf 'tab_id=%s\n' "$tab"
    printf 'pane_id=%s\n' "$pane"
    printf 'parent_workspace_id=%s\n' "$parent_workspace"
    printf 'parent_label=%s\n' "$parent_label"
    printf 'workspace_label=%s\n' "$workspace_label"
    printf 'task_label=%s\n' "$task_label"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  [ -f "$journal" ] && [ ! -L "$journal" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$journal"
}

fm_backend_herdr_projection_journal_write_v3() {  # <journal> <task-id> <task-kind> <token> <home> <session> <workspace> <tab> <pane> <parent-workspace> <parent-label> <workspace-label> <task-label>
  local journal=$1 id=$2 task_kind=$3 token=$4 home=$5 session=$6 workspace=$7 tab=$8 pane=$9
  local parent_workspace=${10} parent_label=${11} workspace_label=${12} task_label=${13} state tmp
  state=$(dirname "$journal")
  tmp=$(mktemp "$state/.${id}.herdr-presentation.bind.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! {
    printf 'version=3\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
    printf 'task_kind=%s\n' "$task_kind"
    printf 'home=%s\n' "$home"
    printf 'session=%s\n' "$session"
    printf 'workspace_id=%s\n' "$workspace"
    printf 'tab_id=%s\n' "$tab"
    printf 'pane_id=%s\n' "$pane"
    printf 'parent_workspace_id=%s\n' "$parent_workspace"
    printf 'parent_label=%s\n' "$parent_label"
    printf 'workspace_label=%s\n' "$workspace_label"
    printf 'task_label=%s\n' "$task_label"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  [ -f "$journal" ] && [ ! -L "$journal" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$journal"
}

# fm_backend_herdr_projection_journal_bind: upgrade one exact version 1
# attempt to a version 3 binding after the readable live projection and parent
# relation have both been verified under the session lock.
fm_backend_herdr_projection_journal_bind() {  # <journal> <task-id> <task-kind> <home> <session> <workspace> <tab> <pane> <parent-workspace> <parent-label> <workspace-label> <task-label>
  local journal=$1 id=$2 task_kind=$3 home=$4 session=$5 workspace=$6 tab=$7 pane=$8
  local parent_workspace=$9 parent_label=${10} workspace_label=${11} task_label=${12} token expected_task_label
  fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || return 1
  [ "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION" = 1 ] || return 1
  expected_task_label=$(FM_HOME="$home" fm_backend_herdr_task_label "$id" "$task_kind") || return 1
  [ "$task_label" = "$expected_task_label" ] || return 1
  token=$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID
  fm_backend_herdr_projection_journal_write_v3 \
    "$journal" "$id" "$task_kind" "$token" "$home" "$session" "$workspace" "$tab" "$pane" \
    "$parent_workspace" "$parent_label" "$workspace_label" "$task_label"
}

# fm_backend_herdr_projection_journal_replace_endpoint: atomically advance a
# version 2 or 3 exact binding after its old husk was replaced successfully.
# A version 2 replacement migrates to version 3; version 3 retains its exact
# kind and readable label.
fm_backend_herdr_projection_journal_replace_endpoint() {  # <journal> <task-id> <old-tab> <old-pane> <new-tab> <new-pane> <task-kind> <task-label>
  local journal=$1 id=$2 old_tab=$3 old_pane=$4 new_tab=$5 new_pane=$6 task_kind=$7 task_label=$8 expected_task_label
  fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || return 1
  case "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION" in 2|3) ;; *) return 1 ;; esac
  [ "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" = "$old_tab" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" = "$old_pane" ] || return 1
  expected_task_label=$(FM_HOME="$FM_BACKEND_HERDR_JOURNAL_HOME" \
    fm_backend_herdr_task_label "$id" "$task_kind") || return 1
  [ "$task_label" = "$expected_task_label" ] || return 1
  if [ "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION" = 3 ]; then
    [ "$FM_BACKEND_HERDR_JOURNAL_TASK_KIND" = "$task_kind" ] \
      && [ "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" = "$task_label" ] || return 1
  fi
  fm_backend_herdr_projection_journal_write_v3 \
    "$journal" "$id" "$task_kind" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_HOME" "$FM_BACKEND_HERDR_JOURNAL_SESSION" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" "$new_tab" "$new_pane" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" "$task_label"
}

# fm_backend_herdr_projection_concise_task_label: strip redundant owner
# prefixes from a task id used only in the presentation workspace label.
# Removes firstmate/, 2ndmate-<id>/, and a presentation-level fm- owner
# prefix when present. The task tab and pane use the adapter-owned readable
# task label and are not built by this helper.
fm_backend_herdr_projection_concise_task_label() {  # <task-id>
  local task=$1
  case "$task" in
    firstmate/*) task=${task#firstmate/} ;;
    2ndmate-*/*) task=${task#*/} ;;
  esac
  case "$task" in
    fm-*) task=${task#fm-} ;;
  esac
  printf '%s' "$task"
}

# fm_backend_herdr_projection_workspace_label: presentation-only child label.
# Format is literal U+2514 BOX DRAWINGS LIGHT UP AND RIGHT, one space, the
# concise task label, then the unchanged · p:<full-22-char-token> suffix.
# Labels and tokens remain non-authoritative correlators only.
fm_backend_herdr_projection_workspace_label() {  # <task-id> <projection-id>
  printf '└ %s · p:%s' "$(fm_backend_herdr_projection_concise_task_label "$1")" "$2"
}

# fm_backend_herdr_presentation_session_lock_path: one machine-private lock
# path per globally unique physical running Herdr socket, shared across every
# Firstmate home and running name that could mutate that socket. The inventory
# canonicalizes every running socket, refuses aliases or malformed rows, and
# ignores stopped aliases. The path is never under any home's state/.
fm_backend_herdr_presentation_lock_namespace() {
  printf '%s' '/tmp/firstmate-herdr-presentation'
}

fm_backend_herdr_presentation_lock_namespace_mode() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

fm_backend_herdr_presentation_lock_namespace_uid() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%u' "$1" 2>/dev/null
  else
    stat -c '%u' "$1" 2>/dev/null
  fi
}

fm_backend_herdr_presentation_lock_namespace_valid() {
  local dir=$1 expected_uid owner mode
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  expected_uid=$(id -u 2>/dev/null) || return 1
  owner=$(fm_backend_herdr_presentation_lock_namespace_uid "$dir") || return 1
  mode=$(fm_backend_herdr_presentation_lock_namespace_mode "$dir") || return 1
  [ "$owner" = "$expected_uid" ] && [ "$mode" = 700 ]
}

# Canonicalize one absolute running socket to its physical identity. The
# socket itself must resolve, so both a symlinked parent and a symlinked final
# path converge to the same mutation-lock key.
fm_backend_herdr_canonical_socket_path() {  # <absolute-socket-path>
  local socket=${1:-} canonical
  case "$socket" in /*) ;; *) return 1 ;; esac
  command -v realpath >/dev/null 2>&1 || return 1
  canonical=$(realpath "$socket" 2>/dev/null) || return 1
  case "$canonical" in /*) ;; *) return 1 ;; esac
  [ -n "$canonical" ] && [ -e "$canonical" ] || return 1
  printf '%s' "$canonical"
}

# Resolve a requested running name only after canonicalizing every running
# inventory socket. Exactly one running row may name the requested session and
# exactly one running name may resolve to that physical socket. Stopped aliases
# are irrelevant; malformed running inventory grants no mutation lock.
fm_backend_herdr_presentation_session_socket_path() {  # <session>
  local session=$1 sessions rows row name socket canonical requested_count=0 socket_count=0 target=
  [ -n "$session" ] || return 1
  sessions=$(fm_backend_herdr_cli "$session" session list --json 2>/dev/null) || return 1
  rows=$(printf '%s' "$sessions" | jq -er '
    select((.sessions | type) == "array")
    | [.sessions[]? | select(.running == true)] as $running
    | select(all($running[]?;
        (.name | type) == "string" and (.name | length) > 0
        and ((.name | test("[[:space:][:cntrl:]]")) | not)
        and (.socket_path | type) == "string" and (.socket_path | length) > 0))
    | select(([$running[].name] | length) == ([$running[].name] | unique | length))
    | $running[] | [.name,.socket_path] | @tsv
  ' 2>/dev/null) || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name=${row%%$'\t'*}
    socket=${row#*$'\t'}
    [ -n "$name" ] && [ -n "$socket" ] && [ "$socket" != "$row" ] || return 1
    canonical=$(fm_backend_herdr_canonical_socket_path "$socket") || return 1
    if [ "$name" = "$session" ]; then
      requested_count=$((requested_count + 1))
      target=$canonical
    fi
  done <<EOF
$rows
EOF
  [ "$requested_count" -eq 1 ] && [ -n "$target" ] || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    socket=${row#*$'\t'}
    canonical=$(fm_backend_herdr_canonical_socket_path "$socket") || return 1
    [ "$canonical" != "$target" ] || socket_count=$((socket_count + 1))
  done <<EOF
$rows
EOF
  [ "$socket_count" -eq 1 ] || return 1
  printf '%s' "$target"
}

fm_backend_herdr_presentation_session_lock_path() {  # <session>
  local session=$1 socket key dir hash
  [ -n "$session" ] || return 1
  socket=$(fm_backend_herdr_presentation_session_socket_path "$session") || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$socket" | shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$socket" | sha256sum 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
  [ -n "$hash" ] || return 1
  key=${hash:0:32}
  dir=$(fm_backend_herdr_presentation_lock_namespace) || return 1
  [ -n "$dir" ] || return 1
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    if ! mkdir -m 700 "$dir" 2>/dev/null; then
      fm_backend_herdr_presentation_lock_namespace_valid "$dir" || return 1
    fi
  fi
  fm_backend_herdr_presentation_lock_namespace_valid "$dir" || return 1
  printf '%s/order-%s.lock' "$dir" "$key"
}

# fm_backend_herdr_projection_focus_snapshot: print the exact active
# workspace and tab ids as one tab-separated record.
# Presentation mutations use this read-only snapshot as their sole focus
# restoration authority.
# Labels, workspace order, and ambient client state are never focus authority.
fm_backend_herdr_projection_focus_snapshot() {  # <session>
  local session=$1 list snapshot workspace tab tabs
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  snapshot=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.workspace_id | length) > 0)
    | select((.active_tab_id | type) == "string" and (.active_tab_id | length) > 0)
    | [.workspace_id, .active_tab_id]
    | @tsv
  ' 2>/dev/null) || return 1
  [ -n "$snapshot" ] || return 1
  workspace=${snapshot%%$'\t'*}
  tab=${snapshot#*$'\t'}
  [ -n "$workspace" ] && [ -n "$tab" ] && [ "$workspace" != "$tab" ] || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    (.result.tabs | type) == "array"
    and ([.result.tabs[] | select(.focused == true)] | length) == 1
    and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s\t%s' "$workspace" "$tab"
}

# fm_backend_herdr_projection_focus_restore: verify that one presentation
# mutation preserved the exact active workspace and tab captured immediately
# before it.
# Herdr 0.7.4's pane.close can focus an unrelated neighboring workspace when
# it removes a non-focused workspace's last pane.
# A single tab.focus on the exact response-independent pre-operation tab id
# restores both the workspace and tab atomically.
fm_backend_herdr_projection_focus_restore() {  # <session> <snapshot> <operation>
  local session=$1 before=$2 operation=$3 workspace tab after info restored
  [ -n "$before" ] || {
    echo "warning: herdr presentation $operation had no unambiguous pre-operation focus snapshot" >&2
    return 1
  }
  after=$(fm_backend_herdr_projection_focus_snapshot "$session") || after=
  [ "$after" != "$before" ] || return 0
  workspace=${before%%$'\t'*}
  tab=${before#*$'\t'}
  info=$(fm_backend_herdr_cli "$session" tab get "$tab" 2>/dev/null) || {
    echo "warning: herdr presentation $operation changed focus and the exact prior tab could not be verified for restoration" >&2
    return 1
  }
  if ! printf '%s' "$info" | jq -e --arg workspace "$workspace" --arg tab "$tab" '
    .result.tab.workspace_id == $workspace and .result.tab.tab_id == $tab
  ' >/dev/null 2>&1; then
    echo "warning: herdr presentation $operation changed focus and the exact prior tab response was ambiguous" >&2
    return 1
  fi
  fm_backend_herdr_cli "$session" tab focus "$tab" >/dev/null 2>&1 || {
    echo "warning: herdr presentation $operation changed focus and exact-tab restoration failed" >&2
    return 1
  }
  restored=$(fm_backend_herdr_projection_focus_snapshot "$session") || restored=
  if [ "$restored" != "$before" ]; then
    echo "warning: herdr presentation $operation did not restore the exact prior workspace and tab" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_projection_close_pane_focus_preserving: close one exact
# response-derived projection pane without leaving the captain focused
# anywhere else.
# If the target belongs to the active tab, exact tab preservation is
# impossible, so cleanup refuses instead of changing focus.
fm_backend_herdr_projection_close_pane_focus_preserving() {  # <session> <pane-id> [required-agent-state]
  local session=$1 pane_id=$2 required_agent_state=${3:-}
  local before active_tab info target_pane target_tab close_status state
  FM_BACKEND_HERDR_PROJECTION_CLOSE_AGENT_STATE=""
  [ -n "$pane_id" ] || return 0
  before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "warning: herdr presentation cleanup could not capture exact active workspace and tab; refusing focus-unsafe pane close" >&2
    return 1
  }
  active_tab=${before#*$'\t'}
  info=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>/dev/null) || {
    echo "warning: herdr presentation cleanup could not verify the exact pane; refusing focus-unsafe pane close" >&2
    return 1
  }
  target_pane=$(printf '%s' "$info" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  target_tab=$(printf '%s' "$info" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
  if [ "$target_pane" != "$pane_id" ] || [ -z "$target_tab" ]; then
    echo "warning: herdr presentation cleanup received an ambiguous exact-pane response; refusing focus-unsafe pane close" >&2
    return 1
  fi
  if [ "$target_tab" = "$active_tab" ]; then
    echo "warning: herdr presentation cleanup target is the captain's active tab; refusing a close that cannot preserve focus" >&2
    return 1
  fi
  if [ -n "$required_agent_state" ]; then
    state=$(fm_backend_herdr_pane_agent_state "$session" "$pane_id")
    FM_BACKEND_HERDR_PROJECTION_CLOSE_AGENT_STATE=$state
    [ "$state" = "$required_agent_state" ] || return 1
  fi
  if fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1; then
    close_status=0
  else
    close_status=$?
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$before" "pane close" || return 2
  [ "$close_status" -eq 0 ]
}

# fm_backend_herdr_projection_order_best_effort: place the exact workspace id
# returned by THIS projected create immediately after its owning parent's
# contiguous child block and before the next parent.
#
# <parent-label> is the owning FM_HOME label (firstmate or 2ndmate-<id>).
# New-format └ ... · p:<token> children and, for compatibility only, already
# adjacent old-format firstmate/... or 2ndmate-<id>/... projections may extend
# the block read-only; they are never renamed or moved.
#
# This is presentation-only and always returns success.
# Every unavailable, ambiguous, failed, or unverifiable ordering step prints a
# warning and leaves the safely-created worker running in Herdr's current
# order.
# It never looks up a task endpoint, adopts or reuses a workspace, retries an
# ambiguous move, or calls any close/delete/rename primitive.
# The sole move target is <created-workspace-id>, captured directly from the
# current workspace-create response.
# After a successful move, every pre-existing workspace id sequence excluding
# the new id must be byte-identical to the pre-move sequence.
fm_backend_herdr_projection_order_best_effort() {  # <session> <created-workspace-id> <parent-label>
  local session=$1 created=$2 parent=$3 list analysis current desired protocol schema socket mover response move_status focus_before
  local before_existing after_existing
  [ -n "$parent" ] || {
    echo "warning: herdr presentation ordering missing owning parent label; leaving worker in Herdr's current order" >&2
    return 0
  }
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "warning: herdr presentation ordering could not list workspaces; leaving worker in Herdr's current order" >&2
    return 0
  }
  analysis=$(printf '%s' "$list" | jq -c --arg created "$created" --arg parent "$parent" '
    def is_parent:
      (.label | type) == "string" and .label == $parent;
    def is_top_level_parent:
      (.label | type) == "string"
      and (
        (.label == "firstmate")
        or (.label | test("^2ndmate-[^/]+$"))
        or (.label | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,47} · (project|primary|second mate)$"))
      );
    def is_new_child:
      (.label | type) == "string"
      and (.label | test("^└ .+ · p:[A-Za-z0-9_-]{22}$"));
    def is_legacy_child:
      (.label | type) == "string"
      and (.label | test("^(firstmate|2ndmate-[^/]+)/.+ · p:[A-Za-z0-9_-]{22}$"));
    def legacy_owner_for($owner):
      if $owner == "firstmate" or ($owner | test("^2ndmate-[^/]+$")) then $owner
      elif ($owner | endswith(" · project")) or ($owner | endswith(" · primary")) then "firstmate"
      elif ($owner | endswith(" · second mate")) then
        "2ndmate-" + ($owner | sub(" · second mate$"; ""))
      else null
      end;
    def is_legacy_child_for($owner):
      (legacy_owner_for($owner)) as $legacy_owner
      | is_legacy_child
        and $legacy_owner != null
        and (.label | startswith($legacy_owner + "/"));
    def is_child_for($owner):
      is_new_child or is_legacy_child_for($owner);
    (.result.workspaces // null) as $spaces
    | select(($spaces | type) == "array" and ($spaces | length) > 0)
    | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $created)]) as $matches
    | select(($matches | length) == 1)
    | ($matches[0]) as $current
    | select($current == (($spaces | length) - 1))
    | ([range(0; $spaces | length) | select($spaces[.] | is_parent)]) as $parents
    | select(($parents | length) == 1)
    | ($parents[0]) as $pidx
    | select($pidx < $current)
    | (
        reduce range($pidx + 1; $current) as $i (
          0;
          if ($spaces[$i] | is_child_for($parent)) and (. == ($i - $pidx - 1))
          then . + 1
          else .
          end
        )
      ) as $block
    | (reduce range($pidx + 1 + $block; $current) as $i (
        {valid: true, active_parent: null};
        if .valid == false then .
        elif ($spaces[$i] | is_top_level_parent) then
          .active_parent = $spaces[$i].label
        elif ($spaces[$i] | is_new_child) then
          if .active_parent == null then .valid = false else . end
        elif ($spaces[$i] | is_legacy_child) then
          .active_parent as $owner
          | if $owner == null then
              .valid = false
            elif (($spaces[$i] | is_legacy_child_for($owner)) | not) then
              .valid = false
            else
              .
            end
        else
          .active_parent = null
        end
      )) as $remainder
    | select($remainder.valid == true)
    | {
        current: $current,
        desired: ($pidx + 1 + $block),
        parent_index: $pidx,
        existing: [$spaces[] | select(.workspace_id != $created) | .workspace_id]
      }
  ' 2>/dev/null) || analysis=
  [ -n "$analysis" ] || {
    echo "warning: herdr presentation ordering found an ambiguous workspace layout; leaving worker in Herdr's current order" >&2
    return 0
  }
  current=$(printf '%s' "$analysis" | jq -r '.current // empty' 2>/dev/null)
  desired=$(printf '%s' "$analysis" | jq -r '.desired // empty' 2>/dev/null)
  case "$current:$desired" in
    *[!0-9:]*)
      echo "warning: herdr presentation ordering could not parse the target position; leaving worker in Herdr's current order" >&2
      return 0
      ;;
  esac
  [ "$current" != "$desired" ] || return 0

  command -v python3 >/dev/null 2>&1 || {
    echo "warning: herdr presentation ordering requires python3; leaving worker in Herdr's current order" >&2
    return 0
  }
  protocol=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "warning: herdr presentation ordering could not verify the client protocol; leaving worker in Herdr's current order" >&2
      return 0
      ;;
  esac
  if [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL" ]; then
    echo "warning: herdr presentation ordering needs protocol $FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL or newer; leaving worker in Herdr's current order" >&2
    return 0
  fi
  schema=$(fm_backend_herdr_cli "$session" api schema --json 2>/dev/null) || {
    echo "warning: herdr presentation ordering could not read the API schema; leaving worker in Herdr's current order" >&2
    return 0
  }
  if ! printf '%s' "$schema" | jq -e '
    any(.schemas.request.oneOf[]?; .properties.method.const == "workspace.move")
    and .schemas.request["$defs"].WorkspaceMoveParams.required == ["workspace_id", "insert_index"]
    and .schemas.request["$defs"].WorkspaceMoveParams.properties.insert_index.type == "integer"
  ' >/dev/null 2>&1; then
    echo "warning: herdr presentation ordering API support is unavailable or ambiguous; leaving worker in Herdr's current order" >&2
    return 0
  fi
  socket=$(fm_backend_herdr_presentation_session_socket_path "$session") || {
    echo "warning: herdr presentation ordering found an ambiguous named session socket; leaving worker in Herdr's current order" >&2
    return 0
  }

  mover=${FM_BACKEND_HERDR_WORKSPACE_MOVER:-$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-workspace-move.py}
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "warning: herdr presentation ordering could not capture exact active workspace and tab; leaving worker in Herdr's current order" >&2
    return 0
  }
  if response=$("$mover" "$socket" "$created" "$desired" 2>/dev/null); then
    move_status=0
  else
    move_status=$?
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "workspace move" || true
  if [ "$move_status" -ne 0 ]; then
    echo "warning: herdr presentation workspace move failed or had an ambiguous response; leaving worker running without cleanup" >&2
    return 0
  fi
  if ! printf '%s' "$response" | jq -e --arg created "$created" --arg parent "$parent" --argjson desired "$desired" '
    .result.type == "workspace_list"
    and (.result.workspaces | type) == "array"
    and .result.workspaces[$desired].workspace_id == $created
    and ([.result.workspaces[] | select(.label == $parent)] | length) == 1
    and (
      [range(0; .result.workspaces | length) as $i
        | select(.result.workspaces[$i].label == $parent)
        | $i][0] < $desired
    )
  ' >/dev/null 2>&1; then
    echo "warning: herdr presentation workspace move returned an unverifiable order; leaving worker running without cleanup" >&2
    return 0
  fi

  before_existing=$(printf '%s' "$analysis" | jq -c '.existing' 2>/dev/null)
  after_existing=$(printf '%s' "$response" | jq -c --arg created "$created" '[.result.workspaces[] | select(.workspace_id != $created) | .workspace_id]' 2>/dev/null)
  if [ "$after_existing" != "$before_existing" ]; then
    echo "warning: herdr presentation workspace move did not preserve relative order; leaving worker running without cleanup" >&2
  fi
  return 0
}

# fm_backend_herdr_server_ensure: start the herdr server for <session>
# headless (no TUI client) if not already running, mirroring tmux's `tmux
# has-session || tmux new-session -d`. Verified: a bare socket CLI call does
# NOT auto-start the server, so this must run before any workspace/tab/pane
# call. Bounded poll for the server to report running.
fm_backend_herdr_server_ensure() {  # <session>
  local session=$1 running out i
  running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = "true" ] && return 0
  ( fm_backend_herdr_cli "$session" server >/dev/null 2>&1 & ) || return 1
  for i in $(seq 1 20); do
    running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
    [ "$running" = "true" ] && return 0
    sleep 0.5
  done
  echo "error: herdr server for session '$session' did not report running within 10s" >&2
  return 1
}

fm_backend_herdr_meta_field_exact() {  # <metadata-file> <field>
  local meta=$1 field=$2 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${field}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${field}=" "$meta" 2>/dev/null | cut -d= -f2-
}

# Validate one regular non-symlink metadata candidate before any Herdr atomic
# publication or exact-tuple use. An exact backend=herdr claim must be unique;
# routing ids must each be one non-whitespace identity; optional display fields
# must be unique, non-empty, control-free, and bounded; the session alias has
# one fixed value. Records with no Herdr claim remain outside this validator's
# backend-specific schema.
fm_backend_herdr_metadata_validate_record() {  # <metadata-file>
  local meta=$1 field count value backend_count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  backend_count=$(grep -c '^backend=herdr$' "$meta" 2>/dev/null || true)
  [ "$backend_count" -gt 0 ] || return 0
  count=$(grep -c '^backend=' "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] && [ "$backend_count" = 1 ] || {
    echo "error: malformed herdr metadata in $meta: backend must appear exactly once" >&2
    return 1
  }
  for field in herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id; do
    value=$(fm_backend_herdr_meta_field_exact "$meta" "$field" 2>/dev/null || true)
    case "$value" in
      ''|*[[:space:][:cntrl:]]*)
        echo "error: malformed herdr metadata in $meta: $field must be one exact identity" >&2
        return 1
        ;;
    esac
  done
  for field in display_label herdr_session_display_label herdr_workspace_label herdr_tab_label herdr_pane_label; do
    count=$(grep -c "^${field}=" "$meta" 2>/dev/null || true)
    [ "$count" -le 1 ] || {
      echo "error: malformed herdr metadata in $meta: duplicate $field" >&2
      return 1
    }
    [ "$count" = 0 ] && continue
    value=$(fm_backend_herdr_meta_field_exact "$meta" "$field") || return 1
    case "$value" in
      ''|*[[:cntrl:]]*) echo "error: malformed herdr metadata in $meta: invalid $field" >&2; return 1 ;;
    esac
    [ "${#value}" -le 512 ] || {
      echo "error: malformed herdr metadata in $meta: oversized $field" >&2
      return 1
    }
    if [ "$field" = herdr_session_display_label ] \
       && [ "$value" != "$FM_BACKEND_HERDR_SESSION_DISPLAY_LABEL" ]; then
      echo "error: malformed herdr metadata in $meta: dishonest herdr_session_display_label" >&2
      return 1
    fi
  done
}

fm_backend_herdr_metadata_validate_home() {  # <state-directory>
  local state=$1 meta
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    grep -q '^backend=herdr$' "$meta" 2>/dev/null || continue
    fm_backend_herdr_metadata_validate_record "$meta" || return 1
  done
}

# Persist the exact parent tuple inside a marked home so its first child can
# corroborate the stable workspace without adopting it by label. The writer
# creates a mode-0600 same-directory private file, validates the complete Herdr
# record and fixed session alias, then renames it over the exact child-home path.
# Caller-owned recovery validation remains separate and cannot turn this record
# into generic task or projection authority.
fm_backend_herdr_parent_metadata_write() {  # <path> <task-id> <home> <session> <workspace> <tab> <pane> <workspace-label> <task-label>
  local path=$1 id=$2 home=$3 session=$4 workspace=$5 tab=$6 pane=$7 workspace_label=$8 task_label=$9 tmp
  [ "$path" = "$FM_HOME/state/.herdr-parent.meta" ] || return 1
  [ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] || return 1
  tmp=$(mktemp "$FM_HOME/state/.herdr-parent.meta.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! printf '%s\n' \
    'backend=herdr' 'kind=secondmate' "task_id=$id" "project=$home" "home=$home" "worktree=$home" \
    "herdr_session=$session" "herdr_session_display_label=$FM_BACKEND_HERDR_SESSION_DISPLAY_LABEL" \
    "herdr_workspace_id=$workspace" "herdr_tab_id=$tab" "herdr_pane_id=$pane" \
    "display_label=$task_label" "herdr_workspace_label=$workspace_label" \
    "herdr_tab_label=$task_label" "herdr_pane_label=$task_label" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  fm_backend_herdr_metadata_validate_record "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# Validate the one child-home parent record that may recover a second-mate
# publication crash. The path, marker, kind, task, canonical home/project/
# worktree identities, session tuple, fixed alias, and adapter-derived labels
# must all match. This record never becomes generic task metadata and grants no
# projected-fallback authority.
fm_backend_herdr_parent_metadata_validate_recovery() {  # <path> <task-id> <home> <project> <worktree> <session>
  local path=$1 id=$2 home=$3 project=$4 worktree=$5 session=$6 field lines mode
  local expected_home actual subject expected_workspace expected_task
  [ "$path" = "$FM_HOME/state/.herdr-parent.meta" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode=$(fm_backend_herdr_presentation_lock_namespace_mode "$path") || return 1
  [ "$mode" = 600 ] || return 1
  lines=$(wc -l < "$path" 2>/dev/null | tr -d '[:space:]')
  [ "$lines" = 15 ] || return 1
  fm_backend_herdr_metadata_validate_record "$path" || return 1
  [ "$(grep -c '^backend=herdr$' "$path" 2>/dev/null || true)" = 1 ] \
    && [ "$(grep -c '^backend=' "$path" 2>/dev/null || true)" = 1 ] || return 1
  [ "$(fm_backend_herdr_meta_field_exact "$path" kind)" = secondmate ] || return 1
  [ "$(fm_backend_herdr_meta_field_exact "$path" task_id)" = "$id" ] || return 1
  subject=$(fm_backend_herdr_secondmate_subject) || return 1
  [ "$subject" = "$id" ] || return 1
  expected_home=$(fm_backend_herdr_project_identity "$home") || return 1
  for field in project home worktree; do
    actual=$(fm_backend_herdr_meta_field_exact "$path" "$field") || return 1
    actual=$(fm_backend_herdr_project_identity "$actual") || return 1
    [ "$actual" = "$expected_home" ] || return 1
  done
  actual=$(fm_backend_herdr_project_identity "$project") || return 1
  [ "$actual" = "$expected_home" ] || return 1
  actual=$(fm_backend_herdr_project_identity "$worktree") || return 1
  [ "$actual" = "$expected_home" ] || return 1
  [ "$(fm_backend_herdr_meta_field_exact "$path" herdr_session)" = "$session" ] || return 1
  [ "$(fm_backend_herdr_meta_field_exact "$path" herdr_session_display_label)" \
    = "$FM_BACKEND_HERDR_SESSION_DISPLAY_LABEL" ] || return 1
  expected_workspace=$(fm_backend_herdr_workspace_label "$project") || return 1
  expected_task=$(fm_backend_herdr_task_label "$id" secondmate) || return 1
  [ "$(fm_backend_herdr_meta_field_exact "$path" herdr_workspace_label)" = "$expected_workspace" ] || return 1
  for field in display_label herdr_tab_label herdr_pane_label; do
    [ "$(fm_backend_herdr_meta_field_exact "$path" "$field")" = "$expected_task" ] || return 1
  done
}

fm_backend_herdr_metadata_load_tuple() {  # <metadata-file>
  local meta=$1
  fm_backend_herdr_metadata_validate_record "$meta" || return 1
  [ "$(fm_backend_herdr_meta_field_exact "$meta" backend 2>/dev/null)" = herdr ] || return 1
  FM_BACKEND_HERDR_META_SESSION=$(fm_backend_herdr_meta_field_exact "$meta" herdr_session) || return 1
  FM_BACKEND_HERDR_META_WORKSPACE=$(fm_backend_herdr_meta_field_exact "$meta" herdr_workspace_id) || return 1
  FM_BACKEND_HERDR_META_TAB=$(fm_backend_herdr_meta_field_exact "$meta" herdr_tab_id) || return 1
  FM_BACKEND_HERDR_META_PANE=$(fm_backend_herdr_meta_field_exact "$meta" herdr_pane_id) || return 1
}

fm_backend_herdr_metadata_label_matches() {  # <metadata-file> <field> <expected>
  local count value
  count=$(grep -c "^${2}=" "$1" 2>/dev/null || true)
  [ "$count" = 0 ] && return 0
  value=$(fm_backend_herdr_meta_field_exact "$1" "$2") || return 1
  [ "$value" = "$3" ]
}

# Classify one metadata-owned tuple as exact or positively absent at one
# level. Any duplicate, cross-parent, partial, changed, or unreadable shape
# refuses instead of being mistaken for absence.
fm_backend_herdr_live_tuple_state() {  # <session> <workspace> <tab> <pane> <one-pane:0|1> [workspace-list]
  local session=$1 wsid=$2 tab_id=$3 pane_id=$4 one_pane=$5 workspaces=${6:-}
  local tabs panes pane_info code count exact_count pane_count
  FM_BACKEND_HERDR_LIVE_TUPLE_STATE=""
  FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL=""
  FM_BACKEND_HERDR_LIVE_TAB_LABEL=""
  FM_BACKEND_HERDR_LIVE_PANE_LABEL=""
  FM_BACKEND_HERDR_LIVE_PANE_CWD=""
  [ -n "$workspaces" ] || workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$workspaces" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1 || return 1
  count=$(printf '%s' "$workspaces" | jq -r --arg workspace "$wsid" \
    '[.result.workspaces[]? | select(.workspace_id == $workspace)] | length' 2>/dev/null) || return 1
  [ "$count" = 0 ] || [ "$count" = 1 ] || return 1
  if [ "$count" = 0 ]; then
    tabs=$(fm_backend_herdr_cli "$session" tab list 2>/dev/null) || return 1
    printf '%s' "$tabs" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1 || return 1
    count=$(printf '%s' "$tabs" | jq -r --arg tab "$tab_id" \
      '[.result.tabs[]? | select(.tab_id == $tab)] | length' 2>/dev/null) || return 1
    [ "$count" = 0 ] || return 1
    if pane_info=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>&1); then :; fi
    code=$(printf '%s' "$pane_info" | jq -r '.error.code // empty' 2>/dev/null)
    [ "$code" = pane_not_found ] || return 1
    FM_BACKEND_HERDR_LIVE_TUPLE_STATE=missing-workspace
    return 0
  fi
  FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL=$(printf '%s' "$workspaces" | jq -er --arg workspace "$wsid" \
    '.result.workspaces[] | select(.workspace_id == $workspace) | .label | select(type == "string" and length > 0)' 2>/dev/null) || return 1

  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1 || return 1
  count=$(printf '%s' "$tabs" | jq -r --arg tab "$tab_id" \
    '[.result.tabs[]? | select(.tab_id == $tab)] | length' 2>/dev/null) || return 1
  exact_count=$(printf '%s' "$tabs" | jq -r --arg workspace "$wsid" --arg tab "$tab_id" \
    '[.result.tabs[]? | select(.workspace_id == $workspace and .tab_id == $tab)] | length' 2>/dev/null) || return 1
  if [ "$exact_count" = 0 ]; then
    [ "$count" = 0 ] || return 1
    if pane_info=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>&1); then :; fi
    code=$(printf '%s' "$pane_info" | jq -r '.error.code // empty' 2>/dev/null)
    [ "$code" = pane_not_found ] || return 1
    FM_BACKEND_HERDR_LIVE_TUPLE_STATE=missing-tab
    return 0
  fi
  [ "$count" = 1 ] && [ "$exact_count" = 1 ] || return 1
  FM_BACKEND_HERDR_LIVE_TAB_LABEL=$(printf '%s' "$tabs" | jq -er --arg workspace "$wsid" --arg tab "$tab_id" \
    '.result.tabs[] | select(.workspace_id == $workspace and .tab_id == $tab) | .label | select(type == "string" and length > 0)' 2>/dev/null) || return 1

  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1 || return 1
  count=$(printf '%s' "$panes" | jq -r --arg pane "$pane_id" \
    '[.result.panes[]? | select(.pane_id == $pane)] | length' 2>/dev/null) || return 1
  exact_count=$(printf '%s' "$panes" | jq -r --arg tab "$tab_id" --arg pane "$pane_id" \
    '[.result.panes[]? | select(.tab_id == $tab and .pane_id == $pane)] | length' 2>/dev/null) || return 1
  pane_count=$(printf '%s' "$panes" | jq -r --arg tab "$tab_id" \
    '[.result.panes[]? | select(.tab_id == $tab)] | length' 2>/dev/null) || return 1
  if [ "$exact_count" = 0 ]; then
    [ "$count" = 0 ] && [ "$pane_count" = 0 ] || return 1
    if pane_info=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>&1); then :; fi
    code=$(printf '%s' "$pane_info" | jq -r '.error.code // empty' 2>/dev/null)
    [ "$code" = pane_not_found ] || return 1
    FM_BACKEND_HERDR_LIVE_TUPLE_STATE=missing-pane
    return 0
  fi
  [ "$count" = 1 ] && [ "$exact_count" = 1 ] || return 1
  [ "$one_pane" != 1 ] || [ "$pane_count" = 1 ] || return 1
  if pane_info=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>&1); then :; fi
  code=$(printf '%s' "$pane_info" | jq -r '.error.code // empty' 2>/dev/null)
  [ -z "$code" ] || return 1
  printf '%s' "$pane_info" | jq -e --arg workspace "$wsid" --arg tab "$tab_id" --arg pane "$pane_id" \
    '.result.pane.workspace_id == $workspace and .result.pane.tab_id == $tab and .result.pane.pane_id == $pane' >/dev/null 2>&1 || return 1
  FM_BACKEND_HERDR_LIVE_PANE_LABEL=$(printf '%s' "$pane_info" | jq -r '.result.pane.label // empty' 2>/dev/null)
  FM_BACKEND_HERDR_LIVE_PANE_CWD=$(printf '%s' "$pane_info" | jq -r '.result.pane.cwd // empty' 2>/dev/null)
  FM_BACKEND_HERDR_LIVE_TUPLE_STATE=exact
}

fm_backend_herdr_live_tuple_load() {  # <session> <workspace> <tab> <pane> <one-pane:0|1> [workspace-list]
  fm_backend_herdr_live_tuple_state "$@" || return 1
  [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" = exact ]
}

fm_backend_herdr_project_identity() {  # <project-path>
  local project=${1:-}
  [ -n "$project" ] || return 1
  case "$project" in
    /*) ;;
    *) return 1 ;;
  esac
  project=${project%/}
  [ -n "$project" ] || project=/
  if [ -d "$project" ]; then
    (cd "$project" 2>/dev/null && pwd -P)
  else
    printf '%s' "$project"
  fi
}

fm_backend_herdr_workspace_legacy_label() {
  local subject marker="$FM_HOME/$FM_BACKEND_HERDR_SECONDMATE_MARKER"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    subject=$(fm_backend_herdr_secondmate_subject) || return 1
    printf '2ndmate-%s' "$subject"
  else
    printf 'firstmate'
  fi
}

# Resolve one metadata-owned project workspace or stable marked home without
# label adoption. Projected fallback may exclude one child record; v2/v3 may
# select only one exact journal parent id and its derived prior label. Those
# inputs choose a flat parent but never become task ownership evidence.
fm_backend_herdr_workspace_find() {  # <session> <project-or-home> [task-meta] [excluded-meta] [exact-parent-id] [exact-parent-prior-label]
  local session=$1 project=$2 task_meta=${3:-} excluded=${4:-}
  local exact_parent=${5:-} exact_parent_prior=${6:-} state="$FM_HOME/state" parent_meta
  local meta backend kind record_project record_identity record_home home_identity id subject
  local desired prior="" legacy readable task_legacy target_identity list wsid current recorded
  local exact_wsid="" exact_label="" foreign_wsids="" paths="" marked=0 count
  FM_BACKEND_HERDR_WS_FOUND_ID=""
  FM_BACKEND_HERDR_WS_CURRENT_LABEL=""
  fm_backend_herdr_metadata_validate_home "$state" || return 1
  desired=$(fm_backend_herdr_workspace_label "$project") || return 1
  legacy=$(fm_backend_herdr_workspace_legacy_label) || return 1
  target_identity=$(fm_backend_herdr_project_identity "$project") || return 1
  if subject=$(fm_backend_herdr_secondmate_subject 2>/dev/null); then
    marked=1
    target_identity=$(fm_backend_herdr_project_identity "$FM_HOME") || return 1
  else
    prior=$(fm_backend_herdr_workspace_prior_primary_label "$project") || return 1
  fi
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e '
    (.result.workspaces | type) == "array"
    and all(.result.workspaces[]?;
      (.workspace_id | type) == "string" and (.workspace_id | length) > 0
      and (.label | type) == "string" and (.label | length) > 0)
    and ([.result.workspaces[].workspace_id] | length)
        == ([.result.workspaces[].workspace_id] | unique | length)
  ' >/dev/null 2>&1 || return 1

  # A v2/v3 projected fallback may select only its journal-bound flat parent.
  # The journal id grants no task ownership and its prior label is accepted only
  # when it equals this project's derived pre-migration label.
  if [ -n "$exact_parent" ]; then
    case "$exact_parent" in *[[:space:][:cntrl:]]*) return 1 ;; esac
    if [ "$marked" -eq 1 ]; then
      [ -z "$exact_parent_prior" ] || return 1
    else
      [ -z "$exact_parent_prior" ] || [ "$exact_parent_prior" = "$prior" ] || return 1
    fi
    count=$(printf '%s' "$list" | jq -r --arg workspace "$exact_parent" \
      '[.result.workspaces[]? | select(.workspace_id == $workspace)] | length' 2>/dev/null) || return 1
    [ "$count" = 1 ] || return 1
    current=$(printf '%s' "$list" | jq -er --arg workspace "$exact_parent" \
      '.result.workspaces[] | select(.workspace_id == $workspace) | .label' 2>/dev/null) || return 1
    [ "$current" = "$desired" ] \
      || { [ -n "$exact_parent_prior" ] && [ "$current" = "$exact_parent_prior" ]; } || return 1
    count=$(printf '%s' "$list" | jq -r --arg workspace "$exact_parent" --arg desired "$desired" \
      '[.result.workspaces[]? | select(.workspace_id != $workspace and .label == $desired)] | length' 2>/dev/null) || return 1
    [ "$count" = 0 ] || return 1
    FM_BACKEND_HERDR_WS_FOUND_ID=$exact_parent
    FM_BACKEND_HERDR_WS_CURRENT_LABEL=$current
    printf '%s' "$exact_parent"
    return 0
  fi

  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ -z "$excluded" ] || [ "$meta" != "$excluded" ] || continue
    backend=$(fm_backend_herdr_meta_field_exact "$meta" backend 2>/dev/null) || continue
    [ "$backend" = herdr ] || continue
    paths="${paths}${meta}"$'\n'
  done
  parent_meta="$state/.herdr-parent.meta"
  if [ -e "$parent_meta" ] || [ -L "$parent_meta" ]; then
    fm_backend_herdr_metadata_validate_record "$parent_meta" || return 1
    [ "$(fm_backend_herdr_meta_field_exact "$parent_meta" backend 2>/dev/null)" = herdr ] || return 1
    [ -z "$excluded" ] || [ "$parent_meta" != "$excluded" ] \
      || parent_meta=""
    [ -z "$parent_meta" ] || paths="${paths}${parent_meta}"$'\n'
  fi
  if [ -n "$task_meta" ] && { [ -e "$task_meta" ] || [ -L "$task_meta" ]; }; then
    fm_backend_herdr_metadata_validate_record "$task_meta" || return 1
    [ "$(fm_backend_herdr_meta_field_exact "$task_meta" backend 2>/dev/null)" = herdr ] || return 1
    printf '%s' "$paths" | grep -Fqx "$task_meta" || paths="${paths}${task_meta}"$'\n'
  fi

  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    fm_backend_herdr_metadata_load_tuple "$meta" || return 1
    [ "$FM_BACKEND_HERDR_META_SESSION" = "$session" ] || continue
    kind=$(fm_backend_herdr_meta_field_exact "$meta" kind 2>/dev/null) || return 1
    wsid=$FM_BACKEND_HERDR_META_WORKSPACE
    record_project=$(fm_backend_herdr_meta_field_exact "$meta" project 2>/dev/null) || return 1
    record_identity=$(fm_backend_herdr_project_identity "$record_project") || return 1
    if [ "$marked" -eq 1 ]; then
      if [ "$kind" = secondmate ]; then
        case "$meta" in
          */.herdr-parent.meta) id=$(fm_backend_herdr_meta_field_exact "$meta" task_id 2>/dev/null) || return 1 ;;
          *) id=${meta##*/}; id=${id%.meta} ;;
        esac
        [ "$id" = "$subject" ] || return 1
        record_home=$(fm_backend_herdr_meta_field_exact "$meta" home 2>/dev/null) || return 1
        home_identity=$(fm_backend_herdr_project_identity "$record_home") || return 1
        [ "$record_identity" = "$target_identity" ] && [ "$home_identity" = "$target_identity" ] || {
          echo "error: second-mate metadata crosses marked-home identity" >&2
          return 1
        }
      fi
    else
      [ "$kind" != secondmate ] || continue
      if [ "$record_identity" != "$target_identity" ]; then
        foreign_wsids="${foreign_wsids}${wsid}"$'\n'
        continue
      fi
    fi

    fm_backend_herdr_live_tuple_state "$session" "$wsid" \
      "$FM_BACKEND_HERDR_META_TAB" "$FM_BACKEND_HERDR_META_PANE" 0 "$list" || {
      echo "error: unreadable or mismatched live herdr endpoint in $meta" >&2
      return 1
    }
    [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" != missing-workspace ] || continue
    current=$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL
    recorded=$(fm_backend_herdr_meta_field_exact "$meta" herdr_workspace_label 2>/dev/null || true)
    if [ -n "$recorded" ]; then
      [ "$current" = "$recorded" ] || return 1
      [ "$recorded" = "$desired" ] || [ "$recorded" = "$legacy" ] \
        || { [ -n "$prior" ] && [ "$recorded" = "$prior" ]; } \
        || printf '%s\n' "$recorded" | grep -Eq '^└ .+ · p:[A-Za-z0-9_-]{22}$' \
        || return 1
    else
      [ "$current" = "$desired" ] || [ "$current" = "$legacy" ] \
        || { [ -n "$prior" ] && [ "$current" = "$prior" ]; } || return 1
    fi
    case "$meta" in
      */.herdr-parent.meta) id=$(fm_backend_herdr_meta_field_exact "$meta" task_id 2>/dev/null) || return 1 ;;
      *) id=${meta##*/}; id=${id%.meta} ;;
    esac
    readable=$(fm_backend_herdr_task_label "$id" "$kind") || return 1
    task_legacy="fm-$id"
    if [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" != missing-tab ]; then
      recorded=$(fm_backend_herdr_meta_field_exact "$meta" herdr_tab_label 2>/dev/null || true)
      if [ -n "$recorded" ]; then
        [ "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" = "$recorded" ] || return 1
      else
        [ "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" = "$readable" ] \
          || [ "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" = "$task_legacy" ] || return 1
      fi
    fi
    if [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" = exact ]; then
      recorded=$(fm_backend_herdr_meta_field_exact "$meta" herdr_pane_label 2>/dev/null || true)
      if [ -n "$recorded" ]; then
        [ "$FM_BACKEND_HERDR_LIVE_PANE_LABEL" = "$recorded" ] || return 1
      else
        [ -z "$FM_BACKEND_HERDR_LIVE_PANE_LABEL" ] \
          || [ "$FM_BACKEND_HERDR_LIVE_PANE_LABEL" = "$readable" ] \
          || [ "$FM_BACKEND_HERDR_LIVE_PANE_LABEL" = "$task_legacy" ] || return 1
      fi
    fi
    [ -z "$exact_wsid" ] || [ "$exact_wsid" = "$wsid" ] || {
      echo "error: one home identity has multiple live herdr workspaces" >&2
      return 1
    }
    exact_wsid=$wsid
    exact_label=$current
  done <<EOF
$paths
EOF

  if [ -n "$exact_wsid" ]; then
    if printf '%s' "$foreign_wsids" | grep -Fxq "$exact_wsid"; then
      echo "error: one herdr workspace is claimed by multiple canonical projects" >&2
      return 1
    fi
    count=$(printf '%s' "$list" | jq -r --arg workspace "$exact_wsid" --arg desired "$desired" \
      --arg legacy "$legacy" --arg current "$exact_label" --arg prior "$prior" '
      [.result.workspaces[]?
        | select(.workspace_id != $workspace)
        | select(.label == $desired or .label == $legacy or (.label == $current and $current != $prior))]
      | length' 2>/dev/null) || return 1
    [ "$count" = 0 ] || {
      echo "error: duplicate herdr workspace candidate in session $session" >&2
      return 1
    }
    FM_BACKEND_HERDR_WS_FOUND_ID=$exact_wsid
    FM_BACKEND_HERDR_WS_CURRENT_LABEL=$exact_label
    printf '%s' "$exact_wsid"
    return 0
  fi

  count=$(printf '%s' "$list" | jq -r --arg desired "$desired" --arg legacy "$legacy" \
    '[.result.workspaces[]? | select(.label == $desired or .label == $legacy)] | length' 2>/dev/null) || return 1
  [ "$count" = 0 ] || {
    if [ "$marked" -eq 1 ]; then
      echo "error: unowned marked second-mate herdr workspace label collision in session $session" >&2
    else
      echo "error: uncorroborated project herdr workspace candidate in session $session" >&2
    fi
    return 1
  }
}

# fm_backend_herdr_workspace_prune_seeded_default_tab: close EXACTLY
# <seeded_tab_id>, the auto-created default tab id that THIS SAME
# fm_backend_herdr_workspace_ensure call captured straight from its own
# `workspace create` response (never re-derived from a label pattern at
# create_task time - see the incident note below). Best-effort: a failure
# here never fails the caller, mirroring the fm_backend_herdr_kill `|| true`
# contract.
#
# Live-fire incident fix (2026-07-02): the prior implementation
# (fm_backend_herdr_workspace_prune_default_tabs, removed) re-derived
# "prunable" at create_task time from a pure label heuristic - exactly one
# tab, labeled "1" - run against whatever workspace fm_backend_herdr_workspace_find
# had just resolved. Herdr enforces no label uniqueness (docs/herdr-backend.md
# "Label collisions") and derives an unlabeled workspace's DISPLAYED label from
# its pane cwd's basename, so a captain launching herdr directly inside a
# directory named "firstmate" produces a workspace that looks byte-identical,
# by label alone, to firstmate's own auto-created container - one tab, label
# "1". workspace_find adopted that pre-existing (captain-owned, LIVE) workspace
# by the label match, the heuristic matched too, and the very next spawn
# closed the captain's own live pane 27ms after creating its task tab. The
# fix is structural, not another heuristic: only a workspace THIS SAME
# fm_backend_herdr_workspace_ensure call just created carries a non-empty
# seeded_tab_id at all (see FM_BACKEND_HERDR_WS_SEEDED_TAB_ID below); an
# ADOPTED workspace's seeded_tab_id is always empty, so create_task never
# calls this function for one, regardless of how its tabs happen to be
# labeled.
#
# Defense in depth on top of that gate (not the primary safety mechanism):
# re-verify <seeded_tab_id> is still present, still carries label "1" (a
# human could have renamed or repurposed it in the interim), and refuse to
# close it if its pane hosts an actively working agent per herdr's own
# agent-state detection (`agent get`) - belt-and-suspenders against any other
# unforeseen path landing a live agent in a tab this function was about to
# close.
#
# Verified real-herdr behavior (not modeled by the canned-response fake-CLI
# unit tests; modeled by make_herdr_statefake): closing a workspace's LAST
# remaining tab deletes the whole workspace, not just the tab. So this must
# never run while the seeded default tab is still the ONLY tab in the
# workspace - callers only invoke it once at least one other (real task) tab
# exists alongside it, never right after workspace creation - and this
# function independently re-checks the tab count as a second layer.
fm_backend_herdr_workspace_prune_seeded_default_tab() {  # <session> <workspace_id> <seeded_tab_id> [focus-preserving]
  local session=$1 wsid=$2 tab_id=$3 close_mode=${4:-direct} tabs tab_count current_label pane_id agent_out agent_status
  [ -n "$tab_id" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 0
  tab_count=$(printf '%s' "$tabs" | jq -r '.result.tabs? // [] | length' 2>/dev/null)
  case "$tab_count" in ''|*[!0-9]*|0|1) return 0 ;; esac
  current_label=$(printf '%s' "$tabs" | jq -r --arg t "$tab_id" '.result.tabs[]? | select(.tab_id == $t) | .label' 2>/dev/null)
  [ "$current_label" = "1" ] || return 0
  pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || return 0
  [ -n "$pane_id" ] || return 0
  agent_out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>/dev/null)
  agent_status=$(printf '%s' "$agent_out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  [ "$agent_status" = working ] && return 0
  if [ "$close_mode" = focus-preserving ]; then
    fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$pane_id"
  else
    fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1 || true
  fi
}

fm_backend_herdr_workspace_rename_exact() {  # <session> <workspace-id> <label>
  local session=$1 wsid=$2 readable=$3 out
  out=$(fm_backend_herdr_cli "$session" workspace rename "$wsid" "$readable" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e --arg workspace "$wsid" --arg readable "$readable" \
    '.result.workspace.workspace_id == $workspace and .result.workspace.label == $readable' >/dev/null 2>&1
}

fm_backend_herdr_new_pane_rollback() {  # <session> <response-derived-pane-id>
  local session=$1 pane_id=$2
  [ -n "$pane_id" ] || return 0
  fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1 || true
}

# Ensure one readable primary workspace per canonical project, or one stable
# marked workspace for a second-mate home. Existing primary workspaces require
# exact local metadata identity. Only a response-derived pane can be removed
# after a partial new-object failure.
fm_backend_herdr_workspace_ensure() {  # <session> <project-or-home> [task-meta] [excluded-meta] [exact-parent-id] [exact-parent-prior-label]
  local session=$1 project=$2 task_meta=${3:-} excluded=${4:-}
  local exact_parent=${5:-} exact_parent_prior=${6:-}
  local wsid out readable response_label seeded_tab seeded_pane
  FM_BACKEND_HERDR_WS_ID=""
  FM_BACKEND_HERDR_WS_SEEDED_TAB_ID=""
  readable=$(fm_backend_herdr_workspace_label "$project") || return 1
  fm_backend_herdr_workspace_find "$session" "$project" "$task_meta" "$excluded" \
    "$exact_parent" "$exact_parent_prior" >/dev/null || return 1
  wsid=$FM_BACKEND_HERDR_WS_FOUND_ID
  if [ -n "$wsid" ]; then
    if [ "$FM_BACKEND_HERDR_WS_CURRENT_LABEL" != "$readable" ]; then
      fm_backend_herdr_workspace_rename_exact "$session" "$wsid" "$readable" || {
        echo "error: exact herdr workspace $wsid could not be renamed and verified" >&2
        return 1
      }
    fi
    FM_BACKEND_HERDR_WS_ID=$wsid
    printf '%s' "$wsid"
    return 0
  fi

  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$project" --label "$readable" --no-focus 2>/dev/null) || return 1
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  response_label=$(printf '%s' "$out" | jq -r '.result.workspace.label // empty' 2>/dev/null)
  seeded_tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  seeded_pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$wsid" ] || [ "$response_label" != "$readable" ] || [ -z "$seeded_tab" ] || [ -z "$seeded_pane" ]; then
    fm_backend_herdr_new_pane_rollback "$session" "$seeded_pane"
    echo "error: herdr workspace create returned incomplete or mismatched identity data" >&2
    return 1
  fi
  FM_BACKEND_HERDR_WS_ID=$wsid
  FM_BACKEND_HERDR_WS_SEEDED_TAB_ID=$seeded_tab
  printf '%s' "$wsid"
}

# Full spawn-time container ensure; returns container and response-derived
# seeded tab id so only this creation can prune that tab.
fm_backend_herdr_container_ensure() {  # <project-or-home> [task-meta] [excluded-meta] [exact-parent-id] [exact-parent-prior-label]
  local project=${1:-} task_meta=${2:-} excluded=${3:-}
  local exact_parent=${4:-} exact_parent_prior=${5:-} session label
  label=$(fm_backend_herdr_workspace_label "$project") || return 1
  fm_backend_herdr_version_check || return 1
  session=$(fm_backend_herdr_session)
  fm_backend_herdr_server_ensure "$session" || return 1
  fm_backend_herdr_workspace_ensure "$session" "$project" "$task_meta" "$excluded" \
    "$exact_parent" "$exact_parent_prior" >/dev/null || {
    echo "error: failed to ensure herdr workspace '$label' in session '$session'" >&2
    return 1
  }
  [ -n "$FM_BACKEND_HERDR_WS_ID" ] || {
    echo "error: failed to ensure herdr workspace '$label' in session '$session'" >&2
    return 1
  }
  printf '%s:%s\t%s' "$session" "$FM_BACKEND_HERDR_WS_ID" "$FM_BACKEND_HERDR_WS_SEEDED_TAB_ID"
}

# fm_backend_herdr_pane_agent_state: classify <pane_id> in <session> as one of
# dead|no-agent|live|unknown, purely from the JSON body of two read-only
# calls - never from process exit status, since a business-logic "not found"
# response is a normal, expected outcome here, not a call failure (real herdr
# 0.7.1 exits 1 for it; the canned-response test fakes exit 0; parsing only
# the JSON keeps this function correct against either).
#
#   dead     - `pane get` responds with error code pane_not_found: the pane
#              itself is gone (closed, or its process died and herdr already
#              reaped it - verified empirically: killing a pane's shell pid
#              on a live server makes herdr immediately drop both the pane
#              and its tab from `pane get`/`tab list`).
#   no-agent - `pane get` succeeds (the pane structurally exists) but `agent
#              get` responds with error code agent_not_found: nothing is
#              registered in it - exactly what a herdr session-layout restore
#              produces (verified empirically: `session stop` + fresh `herdr
#              server` restart leaves the pane alive, agent_status "unknown",
#              agent get -> agent_not_found - docs/herdr-backend.md "ID
#              stability across a server restart"), and what a future
#              `resume_agents_on_restore = false` restore would produce too
#              (a plain shell, never an agent).
#   live     - `agent get` succeeds and reports a real agent_status (working,
#              idle, done, or blocked - any registered value). An idle or
#              blocked agent is still a genuine, still-registered agent, not
#              a restored husk, so it is never a close-and-replace candidate.
#   unknown  - anything else: an unparseable/unexpected response from either
#              call, or a `pane get` success whose own echoed pane_id does not
#              round-trip (guards against misreading a herdr response shape
#              change as "the pane exists"). The caller must fail safe toward
#              refusal here, never toward closing - this is the conservative
#              backstop the husk check depends on.
fm_backend_herdr_pane_agent_state() {  # <session> <pane_id>
  local session=$1 pane_id=$2 out code pid status
  # 2>&1, not 2>/dev/null: verified empirically that real herdr 0.7.1 writes
  # an error response's JSON body to STDERR (success bodies go to stdout), so
  # discarding stderr here would blind this function to exactly the
  # error.code values (pane_not_found, agent_not_found) it exists to read -
  # every OTHER call site in this file discards stderr safely only because
  # its caller collapses both the error and the not-an-error paths to the
  # same final answer, which this function's dead/no-agent/live/unknown
  # distinction cannot afford to do.
  out=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>&1)
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = "pane_not_found" ] && printf 'dead' || printf 'unknown'
    return 0
  fi
  pid=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  if [ "$pid" != "$pane_id" ]; then
    printf 'unknown'
    return 0
  fi
  out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>&1)
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = "agent_not_found" ] && printf 'no-agent' || printf 'unknown'
    return 0
  fi
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    working|idle|done|blocked) printf 'live' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_tab_is_husk: true (0) only for the two conservative husk
# states (dead, no-agent) fm_backend_herdr_pane_agent_state can positively
# confirm; live and unknown both refuse (1), so an inconclusive read never
# licenses closing anything. Restored-layout recovery depends on this
# fail-safe-toward-refusal behavior.
fm_backend_herdr_tab_is_husk() {  # <session> <pane_id>
  case "$(fm_backend_herdr_pane_agent_state "$1" "$2")" in
    dead|no-agent) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_backend_herdr_agent_state: recovery-grade state for the same session-start
# sweep as the tmux classifier. It reuses the husk classifier rather than
# creating a second Herdr state machine: a structurally gone pane is `missing`,
# a confirmed agent-less pane is `dead`, a registered agent is `alive`, and an
# unexpected or failed API read is `unreadable`.
fm_backend_herdr_agent_state() {  # <target>
  local target=$1
  fm_backend_herdr_parse_target "$target" || { printf 'unreadable'; return 0; }
  case "$(fm_backend_herdr_pane_agent_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" in
    dead) printf 'missing' ;;
    no-agent) printf 'dead' ;;
    live) printf 'alive' ;;
    *) printf 'unreadable' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_herdr_agent_alive() {  # <target>
  case "$(fm_backend_herdr_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_herdr_tab_rename_exact() {  # <session> <workspace-id> <tab-id> <label>
  local session=$1 wsid=$2 tab_id=$3 readable=$4 out
  out=$(fm_backend_herdr_cli "$session" tab rename "$tab_id" "$readable" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e --arg workspace "$wsid" --arg tab "$tab_id" --arg readable "$readable" \
    '.result.tab.workspace_id == $workspace and .result.tab.tab_id == $tab and .result.tab.label == $readable' >/dev/null 2>&1
}

fm_backend_herdr_pane_rename_exact() {  # <session> <workspace-id> <tab-id> <pane-id> <label>
  local session=$1 wsid=$2 tab_id=$3 pane_id=$4 readable=$5 out
  out=$(fm_backend_herdr_cli "$session" pane rename "$pane_id" "$readable" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e --arg workspace "$wsid" --arg tab "$tab_id" --arg pane "$pane_id" --arg readable "$readable" \
    '.result.pane.workspace_id == $workspace and .result.pane.tab_id == $tab and .result.pane.pane_id == $pane and .result.pane.label == $readable' >/dev/null 2>&1
}

# Build one compact husk snapshot from a just-loaded exact tuple. Legacy
# metadata may omit a pane label only when the live label is empty, readable,
# or legacy; a recorded pane label must match exactly.
fm_backend_herdr_husk_snapshot_loaded_exact() {  # <session> <workspace> <tab> <pane> <readable-label> <legacy-label> <recorded-tab-label> <recorded-pane-label> <project-cwd> <worktree-cwd>
  local session=$1 wsid=$2 tab_id=$3 pane_id=$4 readable=$5 legacy=$6
  local recorded_tab=$7 recorded_pane=$8 project_cwd=$9 worktree_cwd=${10}
  local agent_info workspace_label readable_workspace prior_workspace="" legacy_workspace tab_label pane_label pane_cwd
  [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" = exact ] || return 1
  workspace_label=$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL
  readable_workspace=$(fm_backend_herdr_workspace_label "$project_cwd") || return 1
  prior_workspace=$(fm_backend_herdr_workspace_prior_primary_label "$project_cwd" 2>/dev/null || true)
  legacy_workspace=$(fm_backend_herdr_workspace_legacy_label) || return 1
  [ "$workspace_label" = "$readable_workspace" ] || [ "$workspace_label" = "$legacy_workspace" ] \
    || { [ -n "$prior_workspace" ] && [ "$workspace_label" = "$prior_workspace" ]; } || return 1
  tab_label=$FM_BACKEND_HERDR_LIVE_TAB_LABEL
  pane_label=$FM_BACKEND_HERDR_LIVE_PANE_LABEL
  pane_cwd=$FM_BACKEND_HERDR_LIVE_PANE_CWD
  [ "$tab_label" = "$readable" ] || [ "$tab_label" = "$legacy" ] || return 1
  [ -z "$recorded_tab" ] || [ "$tab_label" = "$recorded_tab" ] || return 1
  case "$pane_label" in
    ''|"$readable"|"$legacy") ;;
    *) return 1 ;;
  esac
  [ -z "$recorded_pane" ] || [ "$pane_label" = "$recorded_pane" ] || return 1
  [ "$pane_cwd" = "$project_cwd" ] \
    || { [ -n "$worktree_cwd" ] && [ "$pane_cwd" = "$worktree_cwd" ]; } || return 1
  agent_info=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>&1 || true)
  printf '%s' "$agent_info" | jq -e '
    .error.code == "agent_not_found" and (.result.agent? == null)
  ' >/dev/null 2>&1 || return 1
  jq -cn --arg session "$session" --arg workspace "$wsid" --arg workspace_label "$workspace_label" \
    --arg tab "$tab_id" --arg pane "$pane_id" --arg tab_label "$tab_label" \
    --arg pane_label "$pane_label" --arg cwd "$pane_cwd" \
    '[$session, $workspace, $workspace_label, $tab, $pane, $tab_label, $pane_label, $cwd]'
}

# Read the complete tuple before building the snapshot. The caller compares
# two byte-identical snapshots and performs no read between the second and the
# old-tab close.
fm_backend_herdr_husk_snapshot_exact() {  # <session> <workspace> <tab> <pane> <readable-label> <legacy-label> <recorded-tab-label> <recorded-pane-label> <project-cwd> <worktree-cwd>
  fm_backend_herdr_live_tuple_state "$1" "$2" "$3" "$4" 1 || return 1
  fm_backend_herdr_husk_snapshot_loaded_exact "$@"
}

# Create one readable task. An exact no-agent husk is replaced only after two
# matching snapshots. Positively absent metadata objects are recreated without
# closing or renaming any old object; every ambiguous partial match refuses.
fm_backend_herdr_create_task() {  # <container> <task-id> <task-kind> <cwd> <seeded-tab-id> [task-metadata] [parent-output] [secondmate-parent-recovery]
  local container=$1 id=$2 kind=$3 cwd=$4 seeded_tab_id=${5:-} meta=${6:-} parent_meta=${7:-}
  local parent_recovery=${8:-}
  local session wsid readable legacy list out tab_id pane_id exact_tab="" exact_pane=""
  local matching_count remaining_count collision_exempt="" replace_husk=0 tuple_state=""
  local missing_workspace_label="" missing_tab_label=""
  local meta_workspace meta_project meta_project_identity target_project_identity meta_worktree owner_wsid
  local recorded_workspace_label recorded_tab_label recorded_pane_label current_workspace_label
  local readable_workspace prior_workspace="" legacy_workspace parent_workspace_label snapshot_before snapshot_after
  [ -z "$parent_recovery" ] || [ -z "$meta" ] \
    || { echo "error: task metadata and second-mate parent recovery evidence must stay separate" >&2; return 1; }
  session=${container%%:*}
  wsid=${container#*:}
  readable=$(fm_backend_herdr_task_label "$id" "$kind") || return 1
  legacy="fm-$id"

  if [ -n "$meta" ] && { [ -e "$meta" ] || [ -L "$meta" ]; }; then
    fm_backend_herdr_metadata_load_tuple "$meta" || return 1
    meta_workspace=$FM_BACKEND_HERDR_META_WORKSPACE
    exact_tab=$FM_BACKEND_HERDR_META_TAB
    exact_pane=$FM_BACKEND_HERDR_META_PANE
    [ "$FM_BACKEND_HERDR_META_SESSION" = "$session" ] \
      && [ "$(fm_backend_herdr_meta_field_exact "$meta" kind 2>/dev/null)" = "$kind" ] || {
      echo "error: existing herdr metadata for $id does not match the target session or kind" >&2
      return 1
    }
    meta_project=$(fm_backend_herdr_meta_field_exact "$meta" project 2>/dev/null) || {
      echo "error: existing herdr metadata for $id has no exact project cwd" >&2
      return 1
    }
    meta_project_identity=$(fm_backend_herdr_project_identity "$meta_project") || return 1
    target_project_identity=$(fm_backend_herdr_project_identity "$cwd") || return 1
    [ "$meta_project_identity" = "$target_project_identity" ] || {
      echo "error: existing herdr metadata for $id belongs to another canonical project" >&2
      return 1
    }
    matching_count=$(grep -c '^worktree=' "$meta" 2>/dev/null || true)
    [ "$matching_count" -le 1 ] || {
      echo "error: existing herdr metadata for $id has duplicate worktree cwd fields" >&2
      return 1
    }
    meta_worktree=$(fm_backend_herdr_meta_field_exact "$meta" worktree 2>/dev/null || true)
    recorded_workspace_label=$(fm_backend_herdr_meta_field_exact "$meta" herdr_workspace_label 2>/dev/null || true)
    recorded_tab_label=$(fm_backend_herdr_meta_field_exact "$meta" herdr_tab_label 2>/dev/null || true)
    recorded_pane_label=$(fm_backend_herdr_meta_field_exact "$meta" herdr_pane_label 2>/dev/null || true)
    fm_backend_herdr_live_tuple_state "$session" "$meta_workspace" \
      "$exact_tab" "$exact_pane" 1 || {
      echo "error: existing herdr endpoint for $id is unreadable, changed, duplicate, or cross-parent" >&2
      return 1
    }
    tuple_state=$FM_BACKEND_HERDR_LIVE_TUPLE_STATE
    case "$tuple_state" in
      exact)
        [ "$meta_workspace" = "$wsid" ] || return 1
        snapshot_before=$(fm_backend_herdr_husk_snapshot_loaded_exact \
          "$session" "$wsid" "$exact_tab" "$exact_pane" "$readable" "$legacy" \
          "$recorded_tab_label" "$recorded_pane_label" "$meta_project" "$meta_worktree") || {
          echo "error: exact herdr endpoint for $id has a mismatched label, cwd, pane shape, or agent state" >&2
          return 1
        }
        collision_exempt=$exact_tab
        replace_husk=1
        ;;
      missing-tab|missing-pane)
        [ "$meta_workspace" = "$wsid" ] || return 1
        current_workspace_label=$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL
        readable_workspace=$(fm_backend_herdr_workspace_label "$meta_project") || return 1
        prior_workspace=$(fm_backend_herdr_workspace_prior_primary_label "$meta_project" 2>/dev/null || true)
        legacy_workspace=$(fm_backend_herdr_workspace_legacy_label) || return 1
        if [ -n "$recorded_workspace_label" ]; then
          [ "$current_workspace_label" = "$recorded_workspace_label" ] || return 1
          [ "$recorded_workspace_label" = "$readable_workspace" ] \
            || [ "$recorded_workspace_label" = "$legacy_workspace" ] \
            || { [ -n "$prior_workspace" ] && [ "$recorded_workspace_label" = "$prior_workspace" ]; } \
            || return 1
        else
          [ "$current_workspace_label" = "$readable_workspace" ] \
            || [ "$current_workspace_label" = "$legacy_workspace" ] \
            || { [ -n "$prior_workspace" ] && [ "$current_workspace_label" = "$prior_workspace" ]; } \
            || return 1
        fi
        if [ "$tuple_state" = missing-pane ]; then
          if [ -n "$recorded_tab_label" ]; then
            [ "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" = "$recorded_tab_label" ] || return 1
          else
            [ "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" = "$readable" ] \
              || [ "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" = "$legacy" ] || return 1
          fi
          collision_exempt=$exact_tab
        fi
        missing_workspace_label=$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL
        missing_tab_label=$FM_BACKEND_HERDR_LIVE_TAB_LABEL
        ;;
      missing-workspace)
        if [ -z "$seeded_tab_id" ]; then
          owner_wsid=$(fm_backend_herdr_workspace_find "$session" "$cwd" "$meta") || return 1
          [ "$owner_wsid" = "$wsid" ] || return 1
        fi
        ;;
      *) return 1 ;;
    esac
  elif [ -n "$parent_recovery" ]; then
    [ "$kind" = secondmate ] || return 1
    fm_backend_herdr_parent_metadata_validate_recovery \
      "$parent_recovery" "$id" "$cwd" "$cwd" "$cwd" "$session" || {
      echo "error: second-mate parent recovery record for $id is not exact" >&2
      return 1
    }
    fm_backend_herdr_metadata_load_tuple "$parent_recovery" || return 1
    meta_workspace=$FM_BACKEND_HERDR_META_WORKSPACE
    exact_tab=$FM_BACKEND_HERDR_META_TAB
    exact_pane=$FM_BACKEND_HERDR_META_PANE
    [ "$meta_workspace" = "$wsid" ] || return 1
    meta_project=$(fm_backend_herdr_meta_field_exact "$parent_recovery" project) || return 1
    meta_worktree=$(fm_backend_herdr_meta_field_exact "$parent_recovery" worktree) || return 1
    recorded_workspace_label=$(fm_backend_herdr_meta_field_exact \
      "$parent_recovery" herdr_workspace_label) || return 1
    recorded_tab_label=$(fm_backend_herdr_meta_field_exact \
      "$parent_recovery" herdr_tab_label) || return 1
    recorded_pane_label=$(fm_backend_herdr_meta_field_exact \
      "$parent_recovery" herdr_pane_label) || return 1
    fm_backend_herdr_live_tuple_state "$session" "$meta_workspace" \
      "$exact_tab" "$exact_pane" 1 || return 1
    [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" = exact ] || {
      echo "error: second-mate parent recovery requires its exact existing workspace, tab, and pane" >&2
      return 1
    }
    snapshot_before=$(fm_backend_herdr_husk_snapshot_loaded_exact \
      "$session" "$wsid" "$exact_tab" "$exact_pane" "$readable" "$legacy" \
      "$recorded_tab_label" "$recorded_pane_label" "$meta_project" "$meta_worktree") || {
      echo "error: second-mate parent recovery endpoint is not one exact no-agent husk" >&2
      return 1
    }
    collision_exempt=$exact_tab
    replace_husk=1
  fi

  list=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1 || {
    echo "error: could not parse herdr tab list output for workspace $wsid (session $session)" >&2
    return 1
  }
  matching_count=$(printf '%s' "$list" | jq -r --arg readable "$readable" --arg legacy "$legacy" --arg exact "$collision_exempt" \
    '[.result.tabs[]? | select((.label == $readable or .label == $legacy) and .tab_id != $exact)] | length' 2>/dev/null)
  [ "$matching_count" = 0 ] || {
    echo "error: herdr tab for $id already exists as an unowned or duplicate candidate; refusing to guess" >&2
    return 1
  }
  case "$tuple_state" in
    missing-workspace|missing-tab|missing-pane)
      fm_backend_herdr_live_tuple_state "$session" "$meta_workspace" "$exact_tab" "$exact_pane" 1 || return 1
      [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" = "$tuple_state" ] \
        && [ "$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL" = "$missing_workspace_label" ] \
        && [ "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" = "$missing_tab_label" ] || {
        echo "error: positively absent herdr endpoint for $id changed before recreation" >&2
        return 1
      }
      ;;
  esac

  out=$(fm_backend_herdr_cli "$session" tab create --workspace "$wsid" --cwd "$cwd" --label "$readable" --no-focus 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane_id=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$tab_id" ] || [ -z "$pane_id" ]; then
    fm_backend_herdr_new_pane_rollback "$session" "$pane_id"
    echo "error: could not parse response-derived tab/pane ids from herdr tab create" >&2
    return 1
  fi
  if ! fm_backend_herdr_tab_rename_exact "$session" "$wsid" "$tab_id" "$readable" \
     || ! fm_backend_herdr_pane_rename_exact "$session" "$wsid" "$tab_id" "$pane_id" "$readable"; then
    fm_backend_herdr_new_pane_rollback "$session" "$pane_id"
    echo "error: new herdr task labels or response identities could not be verified" >&2
    return 1
  fi

  [ -z "$seeded_tab_id" ] || fm_backend_herdr_workspace_prune_seeded_default_tab "$session" "$wsid" "$seeded_tab_id"
  if [ "$replace_husk" = 1 ]; then
    snapshot_after=$(fm_backend_herdr_husk_snapshot_exact \
      "$session" "$wsid" "$exact_tab" "$exact_pane" "$readable" "$legacy" \
      "$recorded_tab_label" "$recorded_pane_label" "$meta_project" "$meta_worktree") || snapshot_after=
    if [ -z "$snapshot_after" ] || [ "$snapshot_after" != "$snapshot_before" ]; then
      fm_backend_herdr_new_pane_rollback "$session" "$pane_id"
      echo "error: exact herdr husk tuple for $id changed before close; refusing stale-tab mutation" >&2
      return 1
    fi
    fm_backend_herdr_cli "$session" tab close "$exact_tab" >/dev/null 2>&1 || true
    list=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || {
      fm_backend_herdr_new_pane_rollback "$session" "$pane_id"
      return 1
    }
    remaining_count=$(printf '%s' "$list" | jq -r --arg old "$exact_tab" --arg new "$tab_id" \
      --arg readable "$readable" --arg legacy "$legacy" \
      '[.result.tabs[]? | select(.tab_id == $old or ((.label == $readable or .label == $legacy) and .tab_id != $new))] | length' 2>/dev/null)
    if [ "$remaining_count" != 0 ]; then
      fm_backend_herdr_new_pane_rollback "$session" "$pane_id"
      echo "error: exact herdr husk replacement for $id did not converge" >&2
      return 1
    fi
  fi
  if [ -n "$parent_meta" ]; then
    [ "$kind" = secondmate ] || return 1
    parent_workspace_label=$(fm_backend_herdr_workspace_label "$cwd") || return 1
    fm_backend_herdr_parent_metadata_write "$parent_meta" "$id" "$cwd" "$session" \
      "$wsid" "$tab_id" "$pane_id" "$parent_workspace_label" "$readable" || {
      fm_backend_herdr_new_pane_rollback "$session" "$pane_id"
      return 1
    }
  fi
  printf '%s %s' "$tab_id" "$pane_id"
}

# fm_backend_herdr_projection_create_task: create one disposable presentation
# workspace and its readable task tab/pane without looking up, adopting, or
# reusing any existing workspace.
# The caller must atomically publish the projection journal first.
# This function sets exact response-derived globals and prints nothing:
#   FM_BACKEND_HERDR_PROJECTION_SESSION
#   FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
#   FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
#   FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
#   FM_BACKEND_HERDR_PROJECTION_TAB_ID
#   FM_BACKEND_HERDR_PROJECTION_PANE_ID
#   FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE
# CLEANUP_SAFE becomes 1 only after both creates returned complete exact IDs.
# A missing, failed, or malformed create response stays ambiguous and grants no
# cleanup authority.
fm_backend_herdr_projection_create_task() {  # <cwd> <workspace-label> <task-label>
  local cwd=$1 workspace_label=$2 task_label=$3 session out tabs panes pane_info tab_count pane_count focus_before
  FM_BACKEND_HERDR_PROJECTION_SESSION=""
  FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID=""
  FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID=""
  FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID=""
  FM_BACKEND_HERDR_PROJECTION_TAB_ID=""
  FM_BACKEND_HERDR_PROJECTION_PANE_ID=""
  FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE=0

  fm_backend_herdr_version_check || return 1
  session=$(fm_backend_herdr_session)
  fm_backend_herdr_server_ensure "$session" || return 1
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "error: herdr presentation workspace create could not capture exact active workspace and tab; refusing a focus-unsafe projection" >&2
    return 1
  }
  if out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$cwd" --label "$workspace_label" --no-focus 2>/dev/null); then
    :
  else
    fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "workspace create" || true
    echo "error: herdr presentation workspace create failed ambiguously; leaving its journal quarantined" >&2
    return 1
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "workspace create" || {
    echo "error: herdr presentation workspace create did not preserve exact active focus; leaving its journal quarantined" >&2
    return 1
  }
  # shellcheck disable=SC2034  # caller consumes the response-derived global
  FM_BACKEND_HERDR_PROJECTION_SESSION=$session
  FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" ] \
     || [ -z "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" ] \
     || [ -z "$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID" ]; then
    echo "error: herdr presentation workspace create returned incomplete IDs; leaving its journal quarantined" >&2
    return 1
  fi

  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "error: herdr presentation task-tab create could not capture exact active workspace and tab; refusing a focus-unsafe projection" >&2
    return 1
  }
  if out=$(fm_backend_herdr_cli "$session" tab create \
    --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
    --cwd "$cwd" --label "$task_label" --no-focus 2>/dev/null); then
    :
  else
    fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "task-tab create" || true
    echo "error: herdr presentation task-tab create failed ambiguously; leaving its journal quarantined" >&2
    return 1
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "task-tab create" || {
    echo "error: herdr presentation task-tab create did not preserve exact active focus; leaving its journal quarantined" >&2
    return 1
  }
  FM_BACKEND_HERDR_PROJECTION_TAB_ID=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  FM_BACKEND_HERDR_PROJECTION_PANE_ID=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" ] || [ -z "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" ]; then
    echo "error: herdr presentation task-tab create returned incomplete IDs; leaving its journal quarantined" >&2
    return 1
  fi
  # shellcheck disable=SC2034  # caller consumes the same-process cleanup gate
  FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE=1
  if ! fm_backend_herdr_tab_rename_exact \
    "$session" "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
    "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" "$task_label" \
     || ! fm_backend_herdr_pane_rename_exact \
       "$session" "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
       "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" "$task_label"; then
    echo "error: herdr presentation task labels or response identities could not be verified" >&2
    return 1
  fi
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "error: herdr presentation seeded-tab prune could not capture exact active workspace and tab; refusing a focus-unsafe prune" >&2
    return 1
  }
  if ! fm_backend_herdr_workspace_prune_seeded_default_tab \
    "$session" \
    "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
    "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" \
    focus-preserving; then
    echo "error: herdr presentation seeded-tab prune refused a focus-unsafe close; leaving its journal quarantined" >&2
    return 1
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "seeded-tab prune" || {
    echo "error: herdr presentation seeded-tab prune did not preserve exact active focus; leaving its journal quarantined" >&2
    return 1
  }

  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" 2>/dev/null) || {
    echo "error: could not verify the disposable herdr presentation workspace shape" >&2
    return 1
  }
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" 2>/dev/null) || {
    echo "error: could not verify the disposable herdr presentation pane shape" >&2
    return 1
  }
  pane_info=$(fm_backend_herdr_cli "$session" pane get "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" 2>/dev/null) || {
    echo "error: could not verify the disposable herdr presentation pane label" >&2
    return 1
  }
  if ! printf '%s' "$tabs" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1 \
     || ! printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1; then
    echo "error: could not parse the disposable herdr presentation workspace shape" >&2
    return 1
  fi
  tab_count=$(printf '%s' "$tabs" | jq -r '.result.tabs | length' 2>/dev/null)
  pane_count=$(printf '%s' "$panes" | jq -r '.result.panes | length' 2>/dev/null)
  if [ "$tab_count" != 1 ] || [ "$pane_count" != 1 ] \
     || ! printf '%s' "$tabs" | jq -e --arg task "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" \
       --arg seeded "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" --arg task_label "$task_label" \
       '.result.tabs[0].tab_id == $task and .result.tabs[0].label == $task_label and ([.result.tabs[] | select(.tab_id == $seeded)] | length) == 0' >/dev/null 2>&1 \
     || ! printf '%s' "$panes" | jq -e --arg pane "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" \
       --arg tab "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" \
       '.result.panes[0].pane_id == $pane and .result.panes[0].tab_id == $tab' >/dev/null 2>&1 \
     || ! printf '%s' "$pane_info" | jq -e --arg workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
       --arg tab "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" --arg pane "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" \
       --arg task_label "$task_label" '
         .result.pane.workspace_id == $workspace
         and .result.pane.tab_id == $tab
         and .result.pane.pane_id == $pane
         and .result.pane.label == $task_label
       ' >/dev/null 2>&1; then
    echo "error: disposable herdr presentation workspace did not converge to exactly one task pane" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_projection_cleanup_exact: same-process abort cleanup for a
# projection whose create calls returned complete exact IDs.
# It performs no lookup and never calls workspace close.
fm_backend_herdr_projection_cleanup_exact() {  # <session> <task-pane> <seeded-pane>
  local session=$1 task_pane=$2 seeded_pane=$3
  [ -z "$task_pane" ] || fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$task_pane" || true
  if [ -n "$seeded_pane" ] && [ "$seeded_pane" != "$task_pane" ]; then
    fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$seeded_pane" || true
  fi
}

# fm_backend_herdr_projection_parent_workspace_exact: resolve one exact parent
# workspace only when its presentation label is unique in the named session.
fm_backend_herdr_projection_parent_workspace_exact() {  # <session> <parent-label>
  local session=$1 parent_label=$2 list
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -er --arg parent_label "$parent_label" '
    (.result.workspaces // null) as $spaces
    | select(($spaces | type) == "array")
    | [$spaces[]? | select(.label == $parent_label)]
    | if length == 1
        and (.[0].workspace_id | type) == "string"
        and (.[0].workspace_id | length) > 0
      then .[0].workspace_id
      else empty
      end
  ' 2>/dev/null
}

# fm_backend_herdr_projection_live_binding_matches: verify one exact projected
# workspace, its single task tab/pane, its unique token label, and its current
# position inside the exact parent's contiguous child block.
# This read-only predicate grants no mutation authority by itself.
fm_backend_herdr_projection_live_binding_matches() {  # <session> <token> <workspace> <tab> <pane> <parent-workspace> <parent-label> <workspace-label> <task-label>
  local session=$1 token=$2 workspace=$3 tab=$4 pane=$5 parent_workspace=$6
  local parent_label=$7 workspace_label=$8 task_label=$9 list tabs panes pane_info
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e \
    --arg token "$token" \
    --arg workspace "$workspace" \
    --arg parent_workspace "$parent_workspace" \
    --arg parent_label "$parent_label" \
    --arg workspace_label "$workspace_label" '
      def is_new_child:
        (.label | type) == "string"
        and (.label | test("^└ .+ · p:[A-Za-z0-9_-]{22}$"));
      def legacy_owner_for($owner):
        if $owner == "firstmate" or ($owner | test("^2ndmate-[^/]+$")) then $owner
        elif ($owner | endswith(" · project")) or ($owner | endswith(" · primary")) then "firstmate"
        elif ($owner | endswith(" · second mate")) then
          "2ndmate-" + ($owner | sub(" · second mate$"; ""))
        else null
        end;
      def is_legacy_child_for($owner):
        (legacy_owner_for($owner)) as $legacy_owner
        | (.label | type) == "string"
          and $legacy_owner != null
          and (.label | test("^(firstmate|2ndmate-[^/]+)/.+ · p:[A-Za-z0-9_-]{22}$"))
          and (.label | startswith($legacy_owner + "/"));
      (.result.workspaces // null) as $spaces
      | select(($spaces | type) == "array")
      | select(([$spaces[]? | select(.workspace_id == $workspace)] | length) == 1)
      | select(([$spaces[]? | select(.workspace_id == $workspace and .label == $workspace_label)] | length) == 1)
      | select(([$spaces[]? | select((.label | type) == "string" and (.label | endswith(" · p:" + $token)))] | length) == 1)
      | select(([$spaces[]? | select((.label | type) == "string" and (.label | endswith(" · p:" + $token)) and .workspace_id == $workspace)] | length) == 1)
      | select(([$spaces[]? | select(.workspace_id == $parent_workspace and .label == $parent_label)] | length) == 1)
      | select(([$spaces[]? | select(.label == $parent_label)] | length) == 1)
      | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $parent_workspace)]) as $parents
      | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $workspace)]) as $children
      | select(($parents | length) == 1 and ($children | length) == 1)
      | ($parents[0]) as $parent_index
      | ($children[0]) as $child_index
      | select($child_index > $parent_index)
      | reduce range($parent_index + 1; $child_index) as $i
          (true; . and (($spaces[$i] | is_new_child) or ($spaces[$i] | is_legacy_child_for($parent_label))))
      | select(. == true)
    ' >/dev/null 2>&1 || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" --arg task_label "$task_label" '
    (.result.tabs | type) == "array"
    and (.result.tabs | length) == 1
    and .result.tabs[0].tab_id == $tab
    and .result.tabs[0].label == $task_label
  ' >/dev/null 2>&1 || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --arg tab "$tab" --arg pane "$pane" '
    (.result.panes | type) == "array"
    and (.result.panes | length) == 1
    and .result.panes[0].pane_id == $pane
    and .result.panes[0].tab_id == $tab
  ' >/dev/null 2>&1 || return 1
  pane_info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  printf '%s' "$pane_info" | jq -e --arg workspace "$workspace" --arg tab "$tab" \
    --arg pane "$pane" --arg task_label "$task_label" '
      .result.pane.workspace_id == $workspace
      and .result.pane.tab_id == $tab
      and .result.pane.pane_id == $pane
      and .result.pane.label == $task_label
    ' >/dev/null 2>&1
}

fm_backend_herdr_projection_reclaim_rollback() {  # <session> <new-pane>
  local session=$1 new_pane=$2 state
  state=$(fm_backend_herdr_pane_agent_state "$session" "$new_pane")
  case "$state" in
    dead) return 0 ;;
    no-agent) ;;
    live|unknown) return 1 ;;
  esac
  fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$new_pane" no-agent || return 1
  [ "$(fm_backend_herdr_pane_agent_state "$session" "$new_pane")" = dead ]
}

# fm_backend_herdr_projection_reclaim_task: replace one exact agent-free
# restored projection husk inside its original workspace.
# The caller holds the session presentation lock and has already established
# that flat fallback is safe across every token match.
# Return 0 means exact reclaim, 2 means non-mutating or exactly rolled-back
# refusal with flat fallback permitted, and 1 means a live/unknown or
# post-mutation uncertainty that must refuse the launch.
fm_backend_herdr_projection_reclaim_task() {  # <session> <journal> <task-id> <home> <meta-workspace> <meta-tab> <meta-pane> <parent-label> <task-kind> <task-label> <cwd>
  local session=$1 journal=$2 id=$3 home=$4 meta_workspace=$5 meta_tab=$6 meta_pane=$7
  local parent_label=$8 task_kind=$9 task_label=${10} cwd=${11} canonical_home state focus_before active_tab out new_tab new_pane close_status
  local old_task_label current_task_label
  FM_BACKEND_HERDR_PROJECTION_TAB_ID=""
  FM_BACKEND_HERDR_PROJECTION_PANE_ID=""
  fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || return 1
  case "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION" in
    2|3) ;;
    *)
      echo "warning: herdr presentation journal for $id has no exact restart binding; spawning flat" >&2
      return 2
      ;;
  esac
  canonical_home=$(fm_backend_herdr_projection_home_identity "$home") || {
    echo "warning: herdr presentation home for $id could not be resolved exactly; spawning flat" >&2
    return 2
  }
  current_task_label=$(FM_HOME="$canonical_home" fm_backend_herdr_task_label "$id" "$task_kind") || return 1
  [ "$task_label" = "$current_task_label" ] || return 1
  old_task_label=$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL
  if [ "$FM_BACKEND_HERDR_JOURNAL_HOME" != "$canonical_home" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" != "$session" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" != "$meta_workspace" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" != "$meta_tab" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" != "$meta_pane" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" != "$parent_label" ]; then
    echo "warning: herdr presentation binding for $id does not match its exact home, endpoint, or parent; spawning flat" >&2
    return 2
  fi
  if [ "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION" = 3 ] \
     && { [ "$FM_BACKEND_HERDR_JOURNAL_TASK_KIND" != "$task_kind" ] \
       || [ "$old_task_label" != "$current_task_label" ]; }; then
    echo "warning: herdr presentation binding for $id does not match its exact task kind or readable label; spawning flat" >&2
    return 2
  fi
  if ! fm_backend_herdr_projection_live_binding_matches \
    "$session" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" \
    "$meta_workspace" "$meta_tab" "$meta_pane" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" "$parent_label" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" "$old_task_label"; then
    echo "warning: herdr presentation binding for $id has an ambiguous, renamed, foreign, or non-nested live shape; spawning flat" >&2
    return 2
  fi
  state=$(fm_backend_herdr_pane_agent_state "$session" "$meta_pane")
  case "$state" in
    no-agent) ;;
    dead)
      echo "warning: exact herdr presentation pane for $id is gone; spawning flat" >&2
      return 2
      ;;
    live|unknown)
      echo "error: exact herdr presentation pane for $id is $state; refusing duplicate launch" >&2
      return 1
      ;;
  esac
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "warning: herdr presentation reclaim for $id could not capture exact focus; spawning flat" >&2
    return 2
  }
  active_tab=${focus_before#*$'\t'}
  if [ "$active_tab" = "$meta_tab" ]; then
    echo "warning: herdr presentation reclaim for $id would replace the active tab; spawning flat" >&2
    return 2
  fi
  if ! out=$(fm_backend_herdr_cli "$session" tab create \
    --workspace "$meta_workspace" --cwd "$cwd" --label "$current_task_label" --no-focus 2>/dev/null); then
    fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "husk replacement create" || return 1
    echo "warning: herdr presentation reclaim for $id could not create an exact replacement; spawning flat" >&2
    return 2
  fi
  new_tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  new_pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$new_tab" ] || [ -z "$new_pane" ]; then
    fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "husk replacement create" || return 1
    echo "warning: herdr presentation reclaim for $id returned ambiguous replacement ids; spawning flat" >&2
    return 2
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "husk replacement create" || return 1
  if ! fm_backend_herdr_tab_rename_exact \
    "$session" "$meta_workspace" "$new_tab" "$current_task_label" \
     || ! fm_backend_herdr_pane_rename_exact \
       "$session" "$meta_workspace" "$new_tab" "$new_pane" "$current_task_label"; then
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    echo "warning: herdr presentation reclaim for $id could not verify its replacement labels; spawning flat" >&2
    return 2
  fi
  state=$(fm_backend_herdr_pane_agent_state "$session" "$meta_pane")
  case "$state" in
    no-agent) ;;
    live|unknown)
      fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
      echo "error: herdr presentation pane for $id became $state during reclaim; refusing duplicate launch" >&2
      return 1
      ;;
    dead)
      fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
      echo "warning: herdr presentation pane for $id disappeared during reclaim; spawning flat" >&2
      return 2
      ;;
  esac
  if fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$meta_pane" no-agent; then
    close_status=0
  else
    close_status=$?
  fi
  if [ "$close_status" -ne 0 ]; then
    if [ "$close_status" -eq 2 ]; then
      return 1
    fi
    state=$FM_BACKEND_HERDR_PROJECTION_CLOSE_AGENT_STATE
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    case "$state" in
      live|unknown)
        echo "error: herdr presentation pane for $id became $state at the close boundary; refusing duplicate launch" >&2
        return 1
        ;;
    esac
    echo "warning: herdr presentation reclaim for $id could not close the exact old husk; spawning flat" >&2
    return 2
  fi
  if [ "$(fm_backend_herdr_pane_agent_state "$session" "$meta_pane")" != dead ]; then
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    return 1
  fi
  if ! fm_backend_herdr_projection_live_binding_matches \
    "$session" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" \
    "$meta_workspace" "$new_tab" "$new_pane" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" "$parent_label" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" "$current_task_label"; then
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    echo "warning: herdr presentation reclaim for $id did not converge exactly; spawning flat" >&2
    return 2
  fi
  if ! fm_backend_herdr_projection_journal_replace_endpoint \
    "$journal" "$id" "$meta_tab" "$meta_pane" "$new_tab" "$new_pane" \
    "$task_kind" "$current_task_label"; then
    fm_backend_herdr_projection_reclaim_rollback "$session" "$new_pane" || return 1
    echo "warning: herdr presentation reclaim for $id could not publish its replacement binding; spawning flat" >&2
    return 2
  fi
  FM_BACKEND_HERDR_PROJECTION_TAB_ID=$new_tab
  FM_BACKEND_HERDR_PROJECTION_PANE_ID=$new_pane
  return 0
}

# fm_backend_herdr_projection_recovery_allows_flat: inspect an existing
# journal's exact token matches without adopting, reusing, renaming, closing,
# or deleting anything.
# Missing matches safely degrade to the normal flat workspace.
# One or more matches allow flat fallback only when every pane is positively
# dead or agent-free; a live or unknown pane refuses a duplicate launch.
fm_backend_herdr_projection_recovery_allows_flat() {  # <session> <journal> <task-id>
  local session=$1 journal=$2 id=$3 token list wsids count wsid panes pane_ids pane state
  FM_BACKEND_HERDR_PROJECTION_TOKEN_MATCH_COUNT=0
  FM_BACKEND_HERDR_PROJECTION_UNIQUE_TOKEN_WORKSPACE_ID=""
  token=$(fm_backend_herdr_projection_journal_token "$journal" "$id") || {
    echo "error: malformed herdr presentation journal for $id; refusing duplicate launch" >&2
    return 1
  }
  fm_backend_herdr_server_ensure "$session" || {
    echo "error: could not inspect the quarantined herdr presentation for $id; refusing duplicate launch" >&2
    return 1
  }
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "error: could not list herdr workspaces while inspecting the quarantined presentation for $id" >&2
    return 1
  }
  if ! printf '%s' "$list" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1; then
    echo "error: could not parse herdr workspaces while inspecting the quarantined presentation for $id" >&2
    return 1
  fi
  wsids=$(printf '%s' "$list" | jq -r --arg suffix " · p:$token" \
    '.result.workspaces[]? | select((.label | type) == "string" and (.label | endswith($suffix))) | .workspace_id' 2>/dev/null)
  count=$(printf '%s\n' "$wsids" | awk 'NF { n += 1 } END { print n + 0 }')
  # shellcheck disable=SC2034  # fm-spawn consumes these same-process evidence globals
  FM_BACKEND_HERDR_PROJECTION_TOKEN_MATCH_COUNT=$count
  if [ "$count" -eq 1 ]; then
    # shellcheck disable=SC2034  # fm-spawn consumes this same-process evidence global
    FM_BACKEND_HERDR_PROJECTION_UNIQUE_TOKEN_WORKSPACE_ID=$wsids
  fi
  if [ "$count" -eq 0 ]; then
    echo "warning: no exact herdr presentation token match for $id; leaving any stale space untouched and spawning flat" >&2
    return 0
  fi
  if [ "$count" -gt 1 ]; then
    echo "warning: $count exact herdr presentation token matches for $id are quarantined; inspecting only for duplicate-agent risk" >&2
  fi
  while IFS= read -r wsid; do
    [ -n "$wsid" ] || continue
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || {
      echo "error: could not inspect herdr presentation workspace $wsid for $id; refusing duplicate launch" >&2
      return 1
    }
    if ! printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1; then
      echo "error: could not parse herdr presentation workspace $wsid for $id; refusing duplicate launch" >&2
      return 1
    fi
    pane_ids=$(printf '%s' "$panes" | jq -r '.result.panes[]? | .pane_id' 2>/dev/null)
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      state=$(fm_backend_herdr_pane_agent_state "$session" "$pane")
      case "$state" in
        dead|no-agent) : ;;
        live|unknown)
          echo "error: quarantined herdr presentation for $id has a $state pane; refusing duplicate launch" >&2
          return 1
          ;;
      esac
    done <<EOF
$pane_ids
EOF
  done <<EOF
$wsids
EOF
  echo "warning: quarantined herdr presentation for $id is dead or agent-free; exact bound reclaim may proceed, otherwise spawning flat" >&2
  return 0
}

# fm_backend_herdr_projection_endpoint_matches_journal: read-only correlation
# for retiring a successful projection journal after normal exact-pane
# teardown.
# Exactly one token-bearing workspace must match the endpoint workspace.
# This verdict never authorizes a Herdr mutation.
fm_backend_herdr_projection_endpoint_matches_journal() {  # <session> <workspace-id> <journal> <task-id>
  local session=$1 workspace_id=$2 journal=$3 id=$4 token list matches
  token=$(fm_backend_herdr_projection_journal_token "$journal" "$id") || return 1
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1 || return 1
  matches=$(printf '%s' "$list" | jq -r --arg suffix " · p:$token" \
    '.result.workspaces[]? | select((.label | type) == "string" and (.label | endswith($suffix))) | .workspace_id' 2>/dev/null)
  [ "$matches" = "$workspace_id" ]
}

fm_backend_herdr_role_transition_path() {  # <state-dir> <task-id>
  printf '%s/%s%s' "$1" "$2" "$FM_BACKEND_HERDR_ROLE_TRANSITION_SUFFIX"
}

fm_backend_herdr_role_transition_field() {  # <intent> <key>
  local intent=$1 key=$2 count
  count=$(grep -c "^${key}=" "$intent" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$intent" 2>/dev/null | cut -d= -f2-
}

# Validate one private, exact-ID, forward-only scout-to-ship intent without
# sourcing it. The captured old label is either the readable scout label or
# the one documented legacy task label; recovery accepts no third spelling.
fm_backend_herdr_role_transition_snapshot() {  # <intent> <task-id>
  local intent=$1 id=$2 lines mode scout legacy worker exact
  FM_BACKEND_HERDR_ROLE_INTENT_TASK_ID=""
  FM_BACKEND_HERDR_ROLE_INTENT_HOME=""
  FM_BACKEND_HERDR_ROLE_INTENT_SESSION=""
  FM_BACKEND_HERDR_ROLE_INTENT_WORKSPACE=""
  FM_BACKEND_HERDR_ROLE_INTENT_TAB=""
  FM_BACKEND_HERDR_ROLE_INTENT_PANE=""
  FM_BACKEND_HERDR_ROLE_INTENT_OLD_LABEL=""
  FM_BACKEND_HERDR_ROLE_INTENT_TARGET_LABEL=""
  [ -f "$intent" ] && [ ! -L "$intent" ] || return 1
  mode=$(fm_backend_herdr_presentation_lock_namespace_mode "$intent") || return 1
  [ "$mode" = 600 ] || return 1
  lines=$(wc -l < "$intent" 2>/dev/null | tr -d '[:space:]')
  [ "$lines" = 11 ] || return 1
  [ "$(fm_backend_herdr_role_transition_field "$intent" version)" = 1 ] || return 1
  FM_BACKEND_HERDR_ROLE_INTENT_TASK_ID=$(fm_backend_herdr_role_transition_field "$intent" task_id) || return 1
  FM_BACKEND_HERDR_ROLE_INTENT_HOME=$(fm_backend_herdr_role_transition_field "$intent" home) || return 1
  FM_BACKEND_HERDR_ROLE_INTENT_SESSION=$(fm_backend_herdr_role_transition_field "$intent" session) || return 1
  FM_BACKEND_HERDR_ROLE_INTENT_WORKSPACE=$(fm_backend_herdr_role_transition_field "$intent" workspace_id) || return 1
  FM_BACKEND_HERDR_ROLE_INTENT_TAB=$(fm_backend_herdr_role_transition_field "$intent" tab_id) || return 1
  FM_BACKEND_HERDR_ROLE_INTENT_PANE=$(fm_backend_herdr_role_transition_field "$intent" pane_id) || return 1
  FM_BACKEND_HERDR_ROLE_INTENT_OLD_LABEL=$(fm_backend_herdr_role_transition_field "$intent" old_label) || return 1
  FM_BACKEND_HERDR_ROLE_INTENT_TARGET_LABEL=$(fm_backend_herdr_role_transition_field "$intent" target_label) || return 1
  [ "$(fm_backend_herdr_role_transition_field "$intent" from_kind)" = scout ] || return 1
  [ "$(fm_backend_herdr_role_transition_field "$intent" to_kind)" = ship ] || return 1
  [ "$FM_BACKEND_HERDR_ROLE_INTENT_TASK_ID" = "$id" ] || return 1
  case "$FM_BACKEND_HERDR_ROLE_INTENT_HOME" in /*) ;; *) return 1 ;; esac
  for exact in "$FM_BACKEND_HERDR_ROLE_INTENT_SESSION" \
    "$FM_BACKEND_HERDR_ROLE_INTENT_WORKSPACE" \
    "$FM_BACKEND_HERDR_ROLE_INTENT_TAB" \
    "$FM_BACKEND_HERDR_ROLE_INTENT_PANE"; do
    case "$exact" in ''|*[[:space:][:cntrl:]]*) return 1 ;; esac
  done
  scout=$(FM_HOME="$FM_BACKEND_HERDR_ROLE_INTENT_HOME" \
    fm_backend_herdr_task_label "$id" scout) || return 1
  worker=$(FM_HOME="$FM_BACKEND_HERDR_ROLE_INTENT_HOME" \
    fm_backend_herdr_task_label "$id" ship) || return 1
  legacy="fm-$id"
  [ "$FM_BACKEND_HERDR_ROLE_INTENT_OLD_LABEL" = "$scout" ] \
    || [ "$FM_BACKEND_HERDR_ROLE_INTENT_OLD_LABEL" = "$legacy" ] || return 1
  [ "$FM_BACKEND_HERDR_ROLE_INTENT_TARGET_LABEL" = "$worker" ]
}

# Atomically publish a private role-transition intent before the first Herdr
# rename. A hard link gives create-if-absent semantics across concurrent or
# interrupted promotion attempts.
fm_backend_herdr_role_transition_create() {  # <state> <task-id> <home> <session> <workspace> <tab> <pane> <old-label> <target-label>
  local state=$1 id=$2 home=$3 session=$4 workspace=$5 tab=$6 pane=$7
  local old_label=$8 target_label=$9 intent tmp
  intent=$(fm_backend_herdr_role_transition_path "$state" "$id")
  if [ -e "$intent" ] || [ -L "$intent" ]; then
    echo "error: herdr role-transition intent already exists for $id" >&2
    return 1
  fi
  tmp=$(mktemp "$state/.${id}.herdr-role-transition.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$id"
    printf 'home=%s\n' "$home"
    printf 'session=%s\n' "$session"
    printf 'workspace_id=%s\n' "$workspace"
    printf 'tab_id=%s\n' "$tab"
    printf 'pane_id=%s\n' "$pane"
    printf 'old_label=%s\n' "$old_label"
    printf 'target_label=%s\n' "$target_label"
    printf 'from_kind=scout\n'
    printf 'to_kind=ship\n'
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! ln "$tmp" "$intent" 2>/dev/null; then
    rm -f "$tmp"
    echo "error: herdr role-transition intent appeared concurrently for $id" >&2
    return 1
  fi
  rm -f "$tmp"
}

# A projected promotion keeps the exact journal-owned workspace and parent.
# This shape check accepts a recoverable old/new tab-pane label mix because
# the caller separately restricts each live label to the intent's two values.
fm_backend_herdr_projection_role_transition_shape_matches() {  # <session> <token> <workspace> <tab> <pane> <parent-workspace> <parent-label> <workspace-label>
  local session=$1 token=$2 workspace=$3 tab=$4 pane=$5 parent_workspace=$6
  local parent_label=$7 workspace_label=$8 list tabs panes
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e \
    --arg token "$token" --arg workspace "$workspace" \
    --arg parent_workspace "$parent_workspace" --arg parent_label "$parent_label" \
    --arg workspace_label "$workspace_label" '
      def is_new_child:
        (.label | type) == "string"
        and (.label | test("^└ .+ · p:[A-Za-z0-9_-]{22}$"));
      def legacy_owner_for($owner):
        if $owner == "firstmate" or ($owner | test("^2ndmate-[^/]+$")) then $owner
        elif ($owner | endswith(" · project")) or ($owner | endswith(" · primary")) then "firstmate"
        elif ($owner | endswith(" · second mate")) then
          "2ndmate-" + ($owner | sub(" · second mate$"; ""))
        else null end;
      def is_legacy_child_for($owner):
        (legacy_owner_for($owner)) as $legacy_owner
        | (.label | type) == "string" and $legacy_owner != null
          and (.label | test("^(firstmate|2ndmate-[^/]+)/.+ · p:[A-Za-z0-9_-]{22}$"))
          and (.label | startswith($legacy_owner + "/"));
      (.result.workspaces // null) as $spaces
      | select(($spaces | type) == "array")
      | select(([$spaces[]? | select(.workspace_id == $workspace and .label == $workspace_label)] | length) == 1)
      | select(([$spaces[]? | select((.label | type) == "string" and (.label | endswith(" · p:" + $token)))] | length) == 1)
      | select(([$spaces[]? | select(.workspace_id == $parent_workspace and .label == $parent_label)] | length) == 1)
      | select(([$spaces[]? | select(.label == $parent_label)] | length) == 1)
      | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $parent_workspace)]) as $parents
      | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $workspace)]) as $children
      | select(($parents | length) == 1 and ($children | length) == 1)
      | ($parents[0]) as $parent_index | ($children[0]) as $child_index
      | select($child_index > $parent_index)
      | reduce range($parent_index + 1; $child_index) as $i
          (true; . and (($spaces[$i] | is_new_child) or ($spaces[$i] | is_legacy_child_for($parent_label))))
      | select(. == true)
    ' >/dev/null 2>&1 || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg workspace "$workspace" --arg tab "$tab" '
    (.result.tabs | type) == "array" and (.result.tabs | length) == 1
    and .result.tabs[0].workspace_id == $workspace
    and .result.tabs[0].tab_id == $tab
  ' >/dev/null 2>&1 || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" '
    (.result.panes | type) == "array" and (.result.panes | length) == 1
    and .result.panes[0].workspace_id == $workspace
    and .result.panes[0].tab_id == $tab
    and .result.panes[0].pane_id == $pane
  ' >/dev/null 2>&1
}

fm_backend_herdr_role_transition_collision_free() {  # <session> <tab-id> <pane-id> <target-label>
  local session=$1 tab=$2 pane=$3 target=$4 tabs workspaces wsids workspace panes count
  tabs=$(fm_backend_herdr_cli "$session" tab list 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1 || return 1
  count=$(printf '%s' "$tabs" | jq -r --arg tab "$tab" --arg target "$target" \
    '[.result.tabs[]? | select(.tab_id != $tab and .label == $target)] | length' 2>/dev/null) || return 1
  [ "$count" = 0 ] || return 1
  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$workspaces" | jq -e '
    (.result.workspaces | type) == "array"
    and all(.result.workspaces[]?; (.workspace_id | type) == "string" and (.workspace_id | length) > 0)
    and ([.result.workspaces[].workspace_id] | length) == ([.result.workspaces[].workspace_id] | unique | length)
  ' >/dev/null 2>&1 || return 1
  wsids=$(printf '%s' "$workspaces" | jq -r '.result.workspaces[].workspace_id' 2>/dev/null) || return 1
  while IFS= read -r workspace; do
    [ -n "$workspace" ] || continue
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || return 1
    printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1 || return 1
    count=$(printf '%s' "$panes" | jq -r --arg pane "$pane" --arg target "$target" \
      '[.result.panes[]? | select(.pane_id != $pane and .label == $target)] | length' 2>/dev/null) || return 1
    [ "$count" = 0 ] || return 1
  done <<EOF
$wsids
EOF
}

# Validate an optional presentation journal against this exact home and tuple.
# Version 1 is token-to-workspace verified and never rewritten. Version 2 must
# still name the legacy label. Version 3 may be the scout source or the exact
# ship target only while a validated intent exists.
fm_backend_herdr_role_transition_journal_preflight() {  # <state> <task-id> <home> <session> <workspace> <tab> <pane> <recorded-workspace-label> <old-label> <target-label> <recovering:0|1>
  local state=$1 id=$2 home=$3 session=$4 workspace=$5 tab=$6 pane=$7
  local recorded_workspace_label=$8 old_label=$9 target_label=${10} recovering=${11}
  local journal canonical_journal_home scout legacy
  FM_BACKEND_HERDR_ROLE_JOURNAL_MODE=none
  FM_BACKEND_HERDR_ROLE_JOURNAL_PATH=$(fm_backend_herdr_projection_journal_path "$state" "$id")
  journal=$FM_BACKEND_HERDR_ROLE_JOURNAL_PATH
  [ -e "$journal" ] || [ -L "$journal" ] || return 0
  fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || {
    echo "error: malformed or unsafe herdr presentation journal for $id" >&2
    return 1
  }
  case "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION" in
    1)
      fm_backend_herdr_projection_endpoint_matches_journal \
        "$session" "$workspace" "$journal" "$id" || {
        echo "error: herdr version 1 presentation journal for $id does not match the exact endpoint" >&2
        return 1
      }
      FM_BACKEND_HERDR_ROLE_JOURNAL_MODE=v1
      return 0
      ;;
    2|3) ;;
    *) return 1 ;;
  esac
  canonical_journal_home=$(fm_backend_herdr_projection_home_identity \
    "$FM_BACKEND_HERDR_JOURNAL_HOME") || return 1
  if [ "$FM_BACKEND_HERDR_JOURNAL_HOME" != "$home" ] \
     || [ "$canonical_journal_home" != "$home" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" != "$session" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" != "$workspace" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" != "$tab" ] \
     || [ "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" != "$pane" ]; then
    echo "error: herdr presentation journal for $id crosses its exact home, session, or endpoint" >&2
    return 1
  fi
  [ -z "$recorded_workspace_label" ] \
    || [ "$recorded_workspace_label" = "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" ] || return 1
  fm_backend_herdr_projection_role_transition_shape_matches \
    "$session" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" \
    "$workspace" "$tab" "$pane" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" || {
    echo "error: herdr presentation journal for $id does not match its exact live projected shape" >&2
    return 1
  }
  scout=$(FM_HOME="$home" fm_backend_herdr_task_label "$id" scout) || return 1
  legacy="fm-$id"
  if [ "$FM_BACKEND_HERDR_JOURNAL_FORMAT_VERSION" = 2 ]; then
    [ "$old_label" = "$legacy" ] \
      && [ "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" = "$legacy" ] || return 1
    FM_BACKEND_HERDR_ROLE_JOURNAL_MODE=v2
    return 0
  fi
  case "$FM_BACKEND_HERDR_JOURNAL_TASK_KIND:$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" in
    "scout:$scout")
      [ "$old_label" = "$scout" ] || return 1
      FM_BACKEND_HERDR_ROLE_JOURNAL_MODE=v3-scout
      ;;
    "ship:$target_label")
      [ "$recovering" = 1 ] || return 1
      FM_BACKEND_HERDR_ROLE_JOURNAL_MODE=v3-ship
      ;;
    *) return 1 ;;
  esac
}

fm_backend_herdr_role_transition_journal_publish() {  # <state> <task-id> <home> <session> <workspace> <tab> <pane> <recorded-workspace-label> <old-label> <target-label>
  local state=$1 id=$2 home=$3 session=$4 workspace=$5 tab=$6 pane=$7
  local recorded_workspace_label=$8 old_label=$9 target_label=${10}
  local journal token journal_home journal_session journal_workspace journal_tab journal_pane
  local parent_workspace parent_label workspace_label
  fm_backend_herdr_role_transition_journal_preflight \
    "$state" "$id" "$home" "$session" "$workspace" "$tab" "$pane" \
    "$recorded_workspace_label" "$old_label" "$target_label" 1 || return 1
  case "$FM_BACKEND_HERDR_ROLE_JOURNAL_MODE" in
    none|v1|v3-ship) return 0 ;;
    v2|v3-scout) ;;
    *) return 1 ;;
  esac
  journal=$FM_BACKEND_HERDR_ROLE_JOURNAL_PATH
  token=$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID
  journal_home=$FM_BACKEND_HERDR_JOURNAL_HOME
  journal_session=$FM_BACKEND_HERDR_JOURNAL_SESSION
  journal_workspace=$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID
  journal_tab=$FM_BACKEND_HERDR_JOURNAL_TAB_ID
  journal_pane=$FM_BACKEND_HERDR_JOURNAL_PANE_ID
  parent_workspace=$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID
  parent_label=$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL
  workspace_label=$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL
  fm_backend_herdr_projection_journal_write_v3 \
    "$journal" "$id" ship "$token" "$journal_home" "$journal_session" \
    "$journal_workspace" "$journal_tab" "$journal_pane" "$parent_workspace" \
    "$parent_label" "$workspace_label" "$target_label"
}

fm_backend_herdr_role_transition_metadata_publish() {  # <metadata> <task-id> <target-label>
  local meta=$1 id=$2 target_label=$3 state tmp line
  state=$(dirname "$meta")
  tmp=$(mktemp "$state/.${id}.meta.promote.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*|display_label=*|herdr_tab_label=*|herdr_pane_label=*) ;;
      *) printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; } ;;
    esac
  done < "$meta"
  {
    printf 'kind=ship\n'
    printf 'display_label=%s\n' "$target_label"
    printf 'herdr_tab_label=%s\n' "$target_label"
    printf 'herdr_pane_label=%s\n' "$target_label"
  } >> "$tmp" || { rm -f "$tmp"; return 1; }
  fm_backend_herdr_metadata_validate_record "$tmp" || { rm -f "$tmp"; return 1; }
  [ "$(fm_backend_herdr_meta_field_exact "$tmp" kind)" = ship ] \
    && [ "$(fm_backend_herdr_meta_field_exact "$tmp" display_label)" = "$target_label" ] \
    && [ "$(fm_backend_herdr_meta_field_exact "$tmp" herdr_tab_label)" = "$target_label" ] \
    && [ "$(fm_backend_herdr_meta_field_exact "$tmp" herdr_pane_label)" = "$target_label" ] \
    || { rm -f "$tmp"; return 1; }
  [ -f "$meta" ] && [ ! -L "$meta" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta"
}

fm_backend_herdr_role_transition_metadata_label_allowed() {  # <metadata> <field> <old-label> <target-label>
  local meta=$1 field=$2 old_label=$3 target_label=$4 count value
  count=$(grep -c "^${field}=" "$meta" 2>/dev/null || true)
  [ "$count" -le 1 ] || return 1
  [ "$count" = 1 ] || return 0
  value=$(fm_backend_herdr_meta_field_exact "$meta" "$field") || return 1
  [ "$value" = "$old_label" ] || [ "$value" = "$target_label" ]
}

# Forward-only, adapter-owned scout-to-ship relabel. The caller holds the task
# lock and the exact named-session lock in that order. Any failure after intent
# publication leaves the validated intent in place, so rerunning promotion can
# converge from any exact old/target mixture without rollback or label lookup.
fm_backend_herdr_promote_scout_to_ship() {  # <state-dir> <metadata> <task-id>
  local state=$1 meta=$2 id=$3 intent canonical_home backend kind window project
  local session workspace tab pane scout worker legacy old_label recorded_workspace_label
  local expected_workspace legacy_workspace live_workspace live_tab live_pane field recovering=0
  [ "$meta" = "$state/$id.meta" ] || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  canonical_home=$(fm_backend_herdr_projection_home_identity "$FM_HOME") || return 1
  fm_backend_herdr_metadata_validate_record "$meta" || return 1
  backend=$(fm_backend_herdr_meta_field_exact "$meta" backend) || return 1
  [ "$backend" = herdr ] || return 1
  kind=$(fm_backend_herdr_meta_field_exact "$meta" kind) || return 1
  case "$kind" in scout|ship) ;; *) return 1 ;; esac
  window=$(fm_backend_herdr_meta_field_exact "$meta" window) || return 1
  project=$(fm_backend_herdr_meta_field_exact "$meta" project) || return 1
  case "$project" in /*) ;; *) return 1 ;; esac
  fm_backend_herdr_metadata_load_tuple "$meta" || return 1
  session=$FM_BACKEND_HERDR_META_SESSION
  workspace=$FM_BACKEND_HERDR_META_WORKSPACE
  tab=$FM_BACKEND_HERDR_META_TAB
  pane=$FM_BACKEND_HERDR_META_PANE
  [ "$window" = "$session:$pane" ] || {
    echo "error: herdr metadata window does not match its exact session and pane" >&2
    return 1
  }
  scout=$(FM_HOME="$canonical_home" fm_backend_herdr_task_label "$id" scout) || return 1
  worker=$(FM_HOME="$canonical_home" fm_backend_herdr_task_label "$id" ship) || return 1
  legacy="fm-$id"
  recorded_workspace_label=$(fm_backend_herdr_meta_field_exact \
    "$meta" herdr_workspace_label 2>/dev/null || true)

  fm_backend_herdr_live_tuple_state "$session" "$workspace" "$tab" "$pane" 1 || {
    echo "error: herdr promotion could not validate the exact live tuple" >&2
    return 1
  }
  [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" = exact ] || return 1
  live_workspace=$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL
  live_tab=$FM_BACKEND_HERDR_LIVE_TAB_LABEL
  live_pane=$FM_BACKEND_HERDR_LIVE_PANE_LABEL
  if [ -n "$recorded_workspace_label" ]; then
    [ "$live_workspace" = "$recorded_workspace_label" ] || return 1
  else
    expected_workspace=$(FM_HOME="$canonical_home" \
      fm_backend_herdr_workspace_label "$project") || return 1
    legacy_workspace=$(FM_HOME="$canonical_home" \
      fm_backend_herdr_workspace_legacy_label) || return 1
    [ "$live_workspace" = "$expected_workspace" ] \
      || [ "$live_workspace" = "$legacy_workspace" ] || return 1
  fi
  fm_backend_herdr_role_transition_collision_free "$session" "$tab" "$pane" "$worker" || {
    echo "error: competing herdr worker label exists for $id" >&2
    return 1
  }

  intent=$(fm_backend_herdr_role_transition_path "$state" "$id")
  if [ -e "$intent" ] || [ -L "$intent" ]; then
    fm_backend_herdr_role_transition_snapshot "$intent" "$id" || {
      echo "error: malformed or unsafe herdr role-transition intent for $id" >&2
      return 1
    }
    [ "$FM_BACKEND_HERDR_ROLE_INTENT_HOME" = "$canonical_home" ] \
      && [ "$FM_BACKEND_HERDR_ROLE_INTENT_SESSION" = "$session" ] \
      && [ "$FM_BACKEND_HERDR_ROLE_INTENT_WORKSPACE" = "$workspace" ] \
      && [ "$FM_BACKEND_HERDR_ROLE_INTENT_TAB" = "$tab" ] \
      && [ "$FM_BACKEND_HERDR_ROLE_INTENT_PANE" = "$pane" ] \
      && [ "$FM_BACKEND_HERDR_ROLE_INTENT_TARGET_LABEL" = "$worker" ] || return 1
    old_label=$FM_BACKEND_HERDR_ROLE_INTENT_OLD_LABEL
    recovering=1
  else
    [ "$kind" = scout ] || {
      echo "error: kind=ship is valid only while resuming its exact herdr role-transition intent" >&2
      return 1
    }
    if [ "$live_tab" != "$live_pane" ] \
       || { [ "$live_tab" != "$scout" ] && [ "$live_tab" != "$legacy" ]; }; then
      echo "error: herdr scout labels are not one exact readable or legacy source" >&2
      return 1
    fi
    old_label=$live_tab
  fi

  [ "$live_tab" = "$old_label" ] || [ "$live_tab" = "$worker" ] || return 1
  [ "$live_pane" = "$old_label" ] || [ "$live_pane" = "$worker" ] || return 1
  for field in display_label herdr_tab_label herdr_pane_label; do
    fm_backend_herdr_role_transition_metadata_label_allowed \
      "$meta" "$field" "$old_label" "$worker" || {
      echo "error: herdr metadata carries a foreign $field during promotion" >&2
      return 1
    }
  done
  fm_backend_herdr_role_transition_journal_preflight \
    "$state" "$id" "$canonical_home" "$session" "$workspace" "$tab" "$pane" \
    "$recorded_workspace_label" "$old_label" "$worker" "$recovering" || return 1

  if [ "$recovering" = 0 ]; then
    fm_backend_herdr_role_transition_create \
      "$state" "$id" "$canonical_home" "$session" "$workspace" "$tab" "$pane" \
      "$old_label" "$worker" || return 1
  fi
  fm_backend_herdr_role_transition_snapshot "$intent" "$id" || return 1
  [ "$FM_BACKEND_HERDR_ROLE_INTENT_HOME" = "$canonical_home" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_SESSION" = "$session" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_WORKSPACE" = "$workspace" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_TAB" = "$tab" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_PANE" = "$pane" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_OLD_LABEL" = "$old_label" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_TARGET_LABEL" = "$worker" ] || return 1
  fm_backend_herdr_live_tuple_state "$session" "$workspace" "$tab" "$pane" 1 || return 1
  [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" = exact ] \
    && [ "$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL" = "$live_workspace" ] || return 1
  live_tab=$FM_BACKEND_HERDR_LIVE_TAB_LABEL
  live_pane=$FM_BACKEND_HERDR_LIVE_PANE_LABEL
  [ "$live_tab" = "$old_label" ] || [ "$live_tab" = "$worker" ] || return 1
  [ "$live_pane" = "$old_label" ] || [ "$live_pane" = "$worker" ] || return 1
  fm_backend_herdr_role_transition_collision_free \
    "$session" "$tab" "$pane" "$worker" || return 1

  if [ "$live_tab" = "$old_label" ]; then
    fm_backend_herdr_tab_rename_exact \
      "$session" "$workspace" "$tab" "$worker" || {
      echo "error: exact herdr tab relabel failed; retained role-transition intent" >&2
      return 1
    }
  fi
  fm_backend_herdr_live_tuple_state "$session" "$workspace" "$tab" "$pane" 1 || return 1
  [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" = exact ] \
    && [ "$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL" = "$live_workspace" ] \
    && [ "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" = "$worker" ] || return 1
  live_pane=$FM_BACKEND_HERDR_LIVE_PANE_LABEL
  [ "$live_pane" = "$old_label" ] || [ "$live_pane" = "$worker" ] || return 1
  if [ "$live_pane" = "$old_label" ]; then
    fm_backend_herdr_pane_rename_exact \
      "$session" "$workspace" "$tab" "$pane" "$worker" || {
      echo "error: exact herdr pane relabel failed; retained role-transition intent" >&2
      return 1
    }
  fi
  fm_backend_herdr_live_tuple_state "$session" "$workspace" "$tab" "$pane" 1 || return 1
  [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" = exact ] \
    && [ "$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL" = "$live_workspace" ] \
    && [ "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" = "$worker" ] \
    && [ "$FM_BACKEND_HERDR_LIVE_PANE_LABEL" = "$worker" ] || return 1

  fm_backend_herdr_role_transition_journal_publish \
    "$state" "$id" "$canonical_home" "$session" "$workspace" "$tab" "$pane" \
    "$recorded_workspace_label" "$old_label" "$worker" || {
    echo "error: herdr presentation binding relabel failed; retained role-transition intent" >&2
    return 1
  }
  fm_backend_herdr_role_transition_metadata_publish "$meta" "$id" "$worker" || {
    echo "error: herdr metadata relabel failed; retained role-transition intent" >&2
    return 1
  }

  fm_backend_herdr_metadata_load_tuple "$meta" || return 1
  [ "$(fm_backend_herdr_meta_field_exact "$meta" kind)" = ship ] \
    && [ "$(fm_backend_herdr_meta_field_exact "$meta" window)" = "$session:$pane" ] \
    && [ "$FM_BACKEND_HERDR_META_SESSION" = "$session" ] \
    && [ "$FM_BACKEND_HERDR_META_WORKSPACE" = "$workspace" ] \
    && [ "$FM_BACKEND_HERDR_META_TAB" = "$tab" ] \
    && [ "$FM_BACKEND_HERDR_META_PANE" = "$pane" ] \
    && [ "$(fm_backend_herdr_meta_field_exact "$meta" display_label)" = "$worker" ] \
    && [ "$(fm_backend_herdr_meta_field_exact "$meta" herdr_tab_label)" = "$worker" ] \
    && [ "$(fm_backend_herdr_meta_field_exact "$meta" herdr_pane_label)" = "$worker" ] || return 1
  fm_backend_herdr_live_tuple_state "$session" "$workspace" "$tab" "$pane" 1 || return 1
  [ "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" = exact ] \
    && [ "$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL" = "$live_workspace" ] \
    && [ "$FM_BACKEND_HERDR_LIVE_TAB_LABEL" = "$worker" ] \
    && [ "$FM_BACKEND_HERDR_LIVE_PANE_LABEL" = "$worker" ] || return 1
  fm_backend_herdr_role_transition_collision_free "$session" "$tab" "$pane" "$worker" || return 1
  fm_backend_herdr_role_transition_journal_preflight \
    "$state" "$id" "$canonical_home" "$session" "$workspace" "$tab" "$pane" \
    "$recorded_workspace_label" "$old_label" "$worker" 1 || return 1
  case "$FM_BACKEND_HERDR_ROLE_JOURNAL_MODE" in
    none|v1|v3-ship) ;;
    *) return 1 ;;
  esac
  fm_backend_herdr_role_transition_snapshot "$intent" "$id" || return 1
  [ "$FM_BACKEND_HERDR_ROLE_INTENT_HOME" = "$canonical_home" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_SESSION" = "$session" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_WORKSPACE" = "$workspace" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_TAB" = "$tab" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_PANE" = "$pane" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_OLD_LABEL" = "$old_label" ] \
    && [ "$FM_BACKEND_HERDR_ROLE_INTENT_TARGET_LABEL" = "$worker" ] || return 1
  rm -f "$intent"
}

# fm_backend_herdr_parse_target: split "<session>:<pane_id>" (pane_id itself
# contains a colon, e.g. "w1:p2") on the FIRST colon only. Sets
# FM_BACKEND_HERDR_SESSION and FM_BACKEND_HERDR_PANE for the caller.
fm_backend_herdr_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_HERDR_SESSION=${target%%:*}
  FM_BACKEND_HERDR_PANE=${target#*:}
  [ -n "$FM_BACKEND_HERDR_SESSION" ] && [ -n "$FM_BACKEND_HERDR_PANE" ] && [ "$FM_BACKEND_HERDR_PANE" != "$target" ]
}

fm_backend_herdr_target_ready() {  # <target>
  fm_backend_herdr_parse_target "$1" || return 1
  fm_backend_herdr_server_ensure "$FM_BACKEND_HERDR_SESSION" || return 1
}

# fm_backend_herdr_current_path: the live FOREGROUND process's cwd, or empty on
# any error. Mirrors tmux's pane_current_path poll used for worktree-path
# discovery after `treehouse get`.
#
# Verified pitfall: `pane get`'s `.result.pane.cwd` is the pane's cwd AT
# CREATION TIME - the top-level shell's cwd - and does NOT update when that
# shell `cd`s or enters a subshell (as `treehouse get` does). Reading it here
# would make fm-spawn.sh's worktree-discovery poll never see the pane "leave"
# the project directory, since `cwd` stays frozen at the original path forever.
# `.result.pane.foreground_cwd` tracks the ACTUALLY RUNNING foreground
# process's cwd instead, which is what changes when `treehouse get` enters its
# worktree subshell - confirmed live against a real treehouse acquisition.
fm_backend_herdr_current_path() {  # <target>
  fm_backend_herdr_target_ready "$1" || return 0
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
    | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null
}

# fm_backend_herdr_send_text_line: send one line of TEXT then submit,
# ATOMICALLY - mirrors tmux's `send-keys -t T text Enter`. Used for the fixed
# spawn-time commands (treehouse get, the GOTMPDIR export). `pane run` types
# the command and submits it in one call (verified).
fm_backend_herdr_send_text_line() {  # <target> <text>
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane run "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# fm_backend_herdr_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately. Mirrors tmux's `send-keys -t T -l text`.
# Verified: `pane send-text` does NOT auto-submit (contrary to the addendum's
# original guess); it behaves exactly like tmux's `-l` literal send.
fm_backend_herdr_send_literal() {  # <target> <text>
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-text "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# fm_backend_herdr_normalize_key: map firstmate's key vocabulary (Enter,
# Escape, C-c, as used by fm-send.sh --key and stuck-crewmate-recovery) onto
# herdr's `pane send-keys` names. Verified empirically: enter, escape/esc, and
# both ctrl+c/C-c all work (case-insensitive on herdr's side, but normalize
# explicitly rather than relying on that).
fm_backend_herdr_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_herdr_send_key: one named special key. Mirrors fm-send.sh's --key
# path (tmux's `send-keys -t T key`).
fm_backend_herdr_send_key() {  # <target> <key>
  fm_backend_herdr_target_ready "$1" || return 1
  local key
  key=$(fm_backend_herdr_normalize_key "$2")
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-keys "$FM_BACKEND_HERDR_PANE" "$key" >/dev/null 2>&1
}

# fm_backend_herdr_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's/fm-watch.sh's `tmux capture-pane -p -t T -S -N`. --source recent
# is the closest herdr analogue to tmux's scrollback-bounded capture.
#
# Verified CLI quirk (herdr-verification-p2.md "pane read --lines bug", v0.7.1):
# `pane read --source recent --lines N` returns COMPLETELY EMPTY output when N
# is smaller than the pane's current viewport height (observed threshold ~23
# rows for a default-sized pane), instead of clamping to the last N lines - it
# does not merely ignore the bound, it drops the read entirely. This silently
# broke exactly the small bounded reads this adapter relies on most (including
# the composer-state guard/fallback reads around submit and injection). Workaround:
# always request a generous fetch far above any realistic viewport height, then
# trim to the caller's requested bound ourselves with `tail`.
fm_backend_herdr_capture() {  # <target> <lines>
  fm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" --source recent --lines "$fetch" 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

fm_backend_herdr_capture_ansi() {  # <target> <lines>
  fm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" --source recent --lines "$fetch" --format ansi 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# Thin adapter over the shared plain-text stripper (bin/fm-composer-lib.sh),
# used only for STRUCTURAL row/shape detection where ghost text must be kept so
# the box border or bare prompt glyph is still visible. Content extraction uses
# the shared fm_composer_strip_ghost instead.
fm_backend_herdr_strip_ansi() {  # <text>
  printf '%s' "$1" | fm_composer_strip_ansi
}

# fm_backend_herdr_composer_state: classify the composer's own row as
# empty|pending|unknown, scanning a generous tail-window capture of <target>.
# herdr's CLI exposes no cursor-row primitive (unlike tmux's #{cursor_y}), so
# this locates the composer structurally, recognizing THREE shapes and keeping
# whichever match comes LAST (scanning forward), so a shape earlier in
# scrollback/a popup can never outrank the real (bottom-anchored) composer:
#
#   bordered - a boxed composer (verified grok 0.2.82): the row's TRIMMED
#              content both STARTS and ENDS with the same border glyph (│, ┃,
#              or a plain ASCII |). The box's own top/bottom rows use rounded
#              corners (╭─…─╮ / ╰─…─╯), which never match; popup item rows and
#              horizontal separator rows carry no border glyph at all; the
#              footer help line ("Enter:send │ … │ …") uses │ only as an
#              INTERIOR separator and does not start with one, so it never
#              matches either.
#   bare     - an UNBORDERED composer (verified real claude 2.x and codex
#              0.142.x, both under herdr 0.7.1, docs/herdr-backend.md
#              "Incident (2026-07-07)"): the row's TRIMMED content starts with
#              one of the verified agent-specific prompt glyphs but carries no
#              closing border at all - claude's own live input row is a bare
#              "❯ …" with no surrounding │, and codex's is a bare "› …". Both
#              harnesses ALSO render bordered decorative boxes elsewhere (a
#              startup welcome banner, an update-available notice) that
#              satisfy the bordered shape above; requiring a match on EITHER
#              shape and keeping the last (bottom-most) one is what keeps the
#              live composer winning over a stale decorative box still sitting
#              in the same capture window - a bordered box is only ever
#              followed later on screen by the actual live composer, never the
#              reverse, in every harness observed so far. The bare shape is
#              deliberately narrower than the bordered content classifier so a
#              no-agent shell fallback prompt (`>`, `$`, `%`, or `#`) falls
#              through to `unknown` instead of being misread as delivered.
#   separated - Pi's composer is one or more content rows between two solid
#              horizontal `─` separator rows, with no prompt glyph or side
#              borders. This shape is accepted ONLY when Herdr's native
#              `agent get` identifies the target as Pi and reports it idle,
#              done, or blocked. A missing/stale/non-Pi agent identity, a
#              working Pi, an over-tall candidate, or an incomplete separator
#              pair remains unknown. This identity + structure conjunction is
#              what makes a blank Pi row safe without weakening dead-shell or
#              ambiguous-pane refusal.
#
#   empty   - blank, a bare prompt glyph, known ghost/placeholder text
#             ("Type a message...", verified grok 0.2.82's empty-composer
#             placeholder), or only de-emphasised ANSI ghost/placeholder text
#             recognized by the shared fm_composer_strip_ghost extractor
#             (dim/faint or dark-TRUECOLOR foreground). Safe to treat as
#             submitted.
#   pending - real, unsubmitted text sits in the composer. This deliberately
#             also covers a slash-command popup that just closed but only
#             auto-completed or filled an argument-hint placeholder into the
#             composer (e.g. "/compact" -> "/compact compaction
#             instructions", verified live against real grok 0.2.82) - that
#             first Enter is a SELECTION, not a submission.
#   unknown - the pane could not be read, or no composer row (of either shape)
#             was found in the captured window.
#
# Ghost/placeholder note: herdr's ANSI pane read preserves the harness's own
# de-emphasis styling, and the classifier extracts real typed content with the
# shared fm_composer_strip_ghost (bin/fm-composer-lib.sh), which drops dim/faint
# runs (claude's rotating prompt suggestion, codex's idle suggestion after the
# bare `›` prompt) AND dark/muted truecolor foreground runs (grok's placeholder),
# while keeping non-de-emphasised real typed input. This is the same owner the
# tmux adapter routes through, so the two backends cannot drift (task
# afk-herdr-false-pending); it superseded a herdr-only faint byte-pattern check
# that recognized only codex's bold-wrapped bare prompt and missed claude's own
# dim ghost - the overnight away-mode injection wedge on the primary claude pane.
FM_BACKEND_HERDR_COMPOSER_LINES=${FM_BACKEND_HERDR_COMPOSER_LINES:-20}
# Known ghost/placeholder composer text. Extend this if another
# herdr-verified harness needs its own idle placeholder recognized.
FM_BACKEND_HERDR_IDLE_RE=${FM_BACKEND_HERDR_IDLE_RE:-'^Type a message\.\.\.$'}
# Known bare (unbordered) prompt glyphs a composer row may start with: ❯
# (claude) and › (codex) only. Generic shell-style glyphs > $ % # are still
# recognized after a bordered composer row has already been structurally found.
FM_BACKEND_HERDR_BARE_PROMPT_RE=${FM_BACKEND_HERDR_BARE_PROMPT_RE:-'^[❯›]'}
# Pi allows a multi-line composer between its horizontal separators. Bound the
# structural candidate so two unrelated transcript rules with an arbitrarily
# large region between them can never be promoted into a composer.
FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES=${FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES:-8}

fm_backend_herdr_pi_separator_row() {  # <plain-row>
  local row=$1
  row="${row#"${row%%[![:space:]]*}"}"
  row="${row%"${row##*[![:space:]]}"}"
  [ "${#row}" -ge 8 ] || return 1
  [ -z "${row//─/}" ]
}

# Locate the content and closing-row position of the bottom-most complete pair
# of Pi separator rows. A separator closes the preceding candidate and
# immediately opens the next, so an earlier transcript rule can never outrank
# the live bottom composer pair. Globals let the caller compare this shape's
# screen position with generic bordered/bare candidates without losing empty
# composer content through command substitution.
fm_backend_herdr_pi_composer_find() {  # <ansi-capture>
  local cap=$1 line plain open=0 lines=0 candidate="" max row=0 open_row=0
  max=$FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES
  case "$max" in ''|*[!0-9]*|0) max=8 ;; esac
  FM_BACKEND_HERDR_PI_PAIR_FOUND=0
  FM_BACKEND_HERDR_PI_PAIR_VALID=0
  FM_BACKEND_HERDR_PI_PAIR_OPEN_LINE=0
  FM_BACKEND_HERDR_PI_PAIR_LINE=0
  FM_BACKEND_HERDR_PI_LAST_SEPARATOR_LINE=0
  FM_BACKEND_HERDR_PI_CONTENT=""
  while IFS= read -r line; do
    row=$((row + 1))
    plain=$(fm_backend_herdr_strip_ansi "$line")
    if fm_backend_herdr_pi_separator_row "$plain"; then
      FM_BACKEND_HERDR_PI_LAST_SEPARATOR_LINE=$row
      if [ "$open" -eq 1 ]; then
        FM_BACKEND_HERDR_PI_PAIR_FOUND=1
        FM_BACKEND_HERDR_PI_PAIR_OPEN_LINE=$open_row
        FM_BACKEND_HERDR_PI_PAIR_LINE=$row
        if [ "$lines" -le "$max" ]; then
          FM_BACKEND_HERDR_PI_PAIR_VALID=1
          FM_BACKEND_HERDR_PI_CONTENT=$candidate
        else
          FM_BACKEND_HERDR_PI_PAIR_VALID=0
          FM_BACKEND_HERDR_PI_CONTENT=""
        fi
      fi
      open=1
      open_row=$row
      lines=0
      candidate=""
    elif [ "$open" -eq 1 ]; then
      [ -z "$candidate" ] || candidate="${candidate}"$'\n'
      candidate="${candidate}${line}"
      lines=$((lines + 1))
    fi
  done <<EOF
$cap
EOF
}

fm_backend_herdr_agent_identity_raw() {  # <session> <pane> -> <agent>\t<status>
  local out
  out=$(fm_backend_herdr_cli "$1" agent get "$2" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '[.result.agent.agent // "", .result.agent.agent_status // ""] | @tsv' 2>/dev/null
}

fm_backend_herdr_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 session pane cap line trimmed found=0 shape="" raw_match="" bordered=0 stripped
  local identity agent agent_status row=0 generic_line=0
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  cap=$(fm_backend_herdr_capture_ansi "$target" "$FM_BACKEND_HERDR_COMPOSER_LINES" 2>/dev/null \
    || fm_backend_herdr_capture "$target" "$FM_BACKEND_HERDR_COMPOSER_LINES") || { printf 'unknown'; return 0; }
  # Structural scan: locate the bottom-most composer row and remember its RAW
  # (styled) bytes. Shape detection runs on the plain row (fm_backend_herdr_strip_ansi
  # keeps ghost text so the border/prompt glyph is still visible); the raw row is
  # kept for ANSI-aware content extraction after the scan.
  while IFS= read -r line; do
    row=$((row + 1))
    trimmed=$(fm_backend_herdr_strip_ansi "$line")
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '│'*'│'|'┃'*'┃'|'|'*'|')
        shape=bordered
        raw_match=$line
        generic_line=$row
        found=1
        ;;
      *)
        if printf '%s' "$trimmed" | grep -qE "$FM_BACKEND_HERDR_BARE_PROMPT_RE"; then
          shape=bare
          raw_match=$line
          generic_line=$row
          found=1
        fi
        ;;
    esac
  done < <(printf '%s\n' "$cap")
  # Pi has no prompt glyph or side border. Compare its bottom-most complete
  # separator pair with the last generic match so an earlier bordered transcript
  # row can never suppress the live Pi composer. Identity is consulted only when
  # a lower separator pair could change the verdict.
  fm_backend_herdr_pi_composer_find "$cap"
  if [ "$FM_BACKEND_HERDR_PI_PAIR_FOUND" -eq 1 ] \
     && [ "$FM_BACKEND_HERDR_PI_PAIR_LINE" -gt "$generic_line" ] \
     && [ "$generic_line" -lt "$FM_BACKEND_HERDR_PI_PAIR_OPEN_LINE" ]; then
    identity=$(fm_backend_herdr_agent_identity_raw "$session" "$pane" 2>/dev/null || true)
    IFS=$'\t' read -r agent agent_status <<EOF
$identity
EOF
    case "$agent:$agent_status" in
      pi:idle|pi:done|pi:blocked)
        if [ "$FM_BACKEND_HERDR_PI_PAIR_VALID" -eq 1 ]; then
          shape=separated
          raw_match=$FM_BACKEND_HERDR_PI_CONTENT
          found=1
        else
          found=0
        fi
        ;;
      pi:*|:*)
        # A working Pi or unreadable identity cannot authorize injection, and
        # the lower separator pair proves any generic row above is not current.
        found=0
        ;;
      *) : ;; # A known non-Pi agent keeps its established generic verdict.
    esac
  elif [ "$FM_BACKEND_HERDR_PI_PAIR_FOUND" -eq 0 ] \
       && [ "$FM_BACKEND_HERDR_PI_LAST_SEPARATOR_LINE" -gt "$generic_line" ]; then
    # A lower unmatched separator proves the generic row is stale, but does
    # not provide the complete Pi composer structure required for injection.
    found=0
  fi
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  # Content: extract the real typed text from the raw row with the shared,
  # fleet-wide ghost stripper (bin/fm-composer-lib.sh), which drops dim/faint AND
  # dark-truecolor ghost/placeholder runs. This replaces the former herdr-only
  # faint byte-pattern check (which recognized only Codex's bold-wrapped bare
  # prompt and missed claude's own dim prompt-suggestion ghost - the overnight
  # afk-herdr-false-pending wedge) and, in a dark theme, drops the composer's own
  # dark box border too, which is why the bordered flag was read from the plain
  # shape above, not from this ghost-stripped content.
  stripped=$(printf '%s\n' "$raw_match" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  if [ "$shape" = bordered ]; then
    bordered=1
    stripped=${stripped//│/}
    stripped=${stripped//┃/}
    stripped=${stripped//|/}
    stripped="${stripped#"${stripped%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
  elif [ "$shape" = separated ]; then
    # The native Pi identity plus the complete separator pair is the genuine
    # composer container, equivalent to a bordered box for shared content
    # classification. ANSI stripping keeps real text and drops only styling.
    bordered=1
  fi
  # Delegate the empty/pending/unknown decision to the shared owner. The bare
  # shape only ever starts with an AGENT glyph (FM_BACKEND_HERDR_BARE_PROMPT_RE
  # is '^[❯›]'), so a bare shell prompt never reaches here - it stays 'unknown'
  # via the no-composer-row path above, exactly as before.
  fm_composer_classify_content "$bordered" "$stripped" "$FM_BACKEND_HERDR_IDLE_RE"
}

# fm_backend_herdr_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until herdr's NATIVE agent-state (agent get)
# confirms a real turn started. Verified hazard (herdr-verification-p2.md
# "slash/$ autocomplete popup"): a `/`- or `$`-prefixed send opens a
# completion popup within ~0.1s, exactly like tmux's claude/codex popups, so
# the caller's <settle> before the first Enter matters here the same way it
# does for tmux.
#
# Confirmation signal (rewritten for the 2026-07-07 incident below;
# superseded a composer-content read that itself replaced a delta-based check
# for the 2026-07-03 incident): when the target is legibly idle before Enter,
# submission is confirmed by fm_backend_herdr_wait_for_working observing a
# submit-active agent_status after Enter, NOT by reading the composer's own
# row. This makes the normal confirmation path cross-agent: it is the same
# semantic signal regardless of what text a harness's idle composer happens
# to display.
#
# Incident (2026-07-07, followed up on 2026-07-08): a redelivery loop in the
# away-mode daemon. Root cause: composer-content submit confirmation was too
# sensitive to harness rendering details. Real claude/codex use bare prompt
# rows, and real codex adds dynamic idle suggestions after `›`; the later
# ANSI-aware composer classifier now handles the pre-injection guard for that
# Codex shape, but idle-baseline submit confirmation deliberately stays on
# native agent-state so delivery does not depend on composer text. Composer
# content is retained for other callers (the away-mode daemon's PRE-injection
# empty-box guard, still dispatched via fm_backend_composer_state /
# fm_backend_herdr_composer_state) and for submit attempts whose pre-Enter
# agent-state baseline is not legibly idle.
#
# This also still correctly handles the earlier 2026-07-03 incident (a
# slash-command popup selection/placeholder-fill on the FIRST Enter is not a
# genuine submission) without any popup-specific logic at all: filling a
# composer placeholder never starts a turn, so agent_status simply never
# reports "working" for that Enter, and the retry loop below sends a second
# Enter exactly as it did before - the fix generalizes instead of special-
# casing the popup shape.
#
# Failure-mode analysis (the two directions the caller-facing contract must
# not get wrong - see docs/herdr-backend.md "Native agent-state submit
# confirmation" for the empirical timing behind this):
#   - Slow transition: fm_backend_herdr_wait_for_working samples repeatedly
#     across herdr's per-attempt confirmation budget (not once at the end), so a
#     transition landing partway through a window is still caught before this
#     loop gives up and sends a needless extra Enter.
#   - Instant round-trip (a turn starts AND returns to idle between two
#     polls): unavoidable in the absolute, but bounded by how tightly polls
#     are packed into the budget; real claude/codex measured first-working
#     at 90-490ms, comfortably inside a several-hundred-ms, multiply-sampled
#     window, so this has not been observed in practice. On the (unobserved)
#     residual chance it happens, the verdict is "pending" and the caller
#     never retypes - only re-sends Enter, which lands on an already-empty
#     composer and is a no-op, not a duplicate delivery of <text> (see
#     fm-send.sh/fm-supervise-daemon.sh: retyping only happens if a caller
#     re-invokes this function from scratch with the same text after seeing
#     an error, which is a human/escalation decision, not an automatic
#     retry).
# Echoes empty|pending|unknown|send-failed, a subset of the proof-carrying
# submit vocabulary. Empty means confirmed submitted for every backend; how
# each backend confirms it is an internal decision, and herdr's is no longer
# literally "the composer read empty".
fm_backend_herdr_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 verdict baseline confirm_sleep
  fm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_herdr_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  baseline=$(fm_backend_herdr_classify_submit_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")")
  confirm_sleep=$(fm_backend_herdr_submit_confirm_budget "$sleep_s")
  while :; do
    fm_backend_herdr_send_key "$target" Enter || true
    if [ "$baseline" = idle ]; then
      verdict=$(fm_backend_herdr_wait_for_working "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
        "$confirm_sleep" "$FM_BACKEND_HERDR_SUBMIT_POLLS")
    else
      sleep "$sleep_s"
      verdict=$(fm_backend_herdr_composer_state "$target")
    fi
    case "$verdict" in
      busy) printf 'empty'; return 0 ;;
      empty) printf 'empty'; return 0 ;;
      unknown) printf 'unknown'; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_backend_herdr_kill: remove the task's pane, best-effort (mirrors
# tmux-kill-window's `|| true` contract). Verified: closing a tab's only pane
# closes the tab too, so a separate tab close is unnecessary.
fm_backend_herdr_kill() {  # <target>
  fm_backend_herdr_target_ready "$1" || return 0
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane close "$FM_BACKEND_HERDR_PANE" >/dev/null 2>&1 || true
}

# fm_backend_herdr_classify_agent_status: map a raw `agent get` agent_status
# value to the adapter's watcher busy|idle|unknown vocabulary. working ->
# busy (actively generating); idle/done -> idle; blocked -> idle (a blocked
# agent is stuck waiting on the human, not grinding - the watcher should
# treat it like a stale pane needing attention, not suppress it as busy);
# unknown/unparseable/empty -> unknown, the caller's cue to fall back to
# pane-regex detection.
fm_backend_herdr_classify_agent_status() {  # <raw-agent_status>
  case "$1" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_herdr_classify_submit_agent_status() {  # <raw-agent_status>
  case "$1" in
    working|blocked) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_agent_status_raw: one `agent get` read, echoing the raw
# agent_status string (working/idle/done/blocked/...), or empty on any
# failure. Deliberately skips fm_backend_herdr_target_ready's server-ensure
# round trip (an extra `status --json` call) that fm_backend_herdr_busy_state
# pays on every call: fm_backend_herdr_wait_for_working polls this in a tight
# loop right after a caller has already parsed the target and confirmed the
# server is live (e.g. fm_backend_herdr_send_text_submit, immediately after a
# successful send-text), so re-checking server liveness on every poll would
# only add latency without adding safety.
fm_backend_herdr_agent_status_raw() {  # <session> <pane_id>
  local session=$1 pane_id=$2 out
  out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>/dev/null) || { printf ''; return 0; }
  printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null
}

# fm_backend_herdr_busy_state: semantic busy state from herdr's native
# agent-state detection (agent.get), the "first backend where fm_session_busy_state
# gets real semantics" per the design report. See
# fm_backend_herdr_classify_agent_status for the status->busy/idle/unknown
# mapping.
fm_backend_herdr_busy_state() {  # <target>
  fm_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  fm_backend_herdr_classify_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")"
}

# fm_backend_herdr_wait_for_working: poll <session>:<pane_id>'s NATIVE
# agent-state (agent get) up to <polls> times spread evenly across
# <budget-seconds>, returning on stdout the STRONGEST signal observed:
#
#   busy    - a submit-active status was observed at least once. This is
#             confirmation that a real turn started or reached a prompt -
#             the submit landed - independent of
#             whatever the composer's own text happens to show (docs/
#             herdr-backend.md "Incident (2026-07-07)": composer content is
#             what fooled the OLD confirmation on codex's dynamic idle-tip
#             text). Returned the INSTANT it is seen, without waiting out the
#             rest of the budget.
#   idle    - the target was legibly read at least once and never reported
#             "busy" across the whole window - a genuine "not (yet)
#             submitted" signal, not a read failure. The caller retries
#             Enter on this verdict.
#   unknown - EVERY poll in the window failed to read the target at all (a
#             hard I/O failure - pane gone, socket error - not a timing
#             race). The caller must not keep retrying Enter against a target
#             it cannot even read.
#
# <polls> spread across <budget-seconds> (rather than one check at the end)
# is what makes this robust against a SLOW transition: a caller now gets
# several samples across that window instead of a single one, so a transition
# that lands partway through is not missed just because it had not landed by
# the FIRST sample.
# Empirical evidence (docs/herdr-backend.md "Native agent-state submit
# confirmation"): real claude and codex observed first-working at 90-490ms
# after Enter, so a several-hundred-ms budget sampled repeatedly reliably
# catches it. The remaining, inherent gap - a turn so fast it starts AND
# returns to idle between two samples - is bounded by how tightly <polls> is
# packed into <budget-seconds>; nothing observed in real testing has come
# close to that, but it is a residual risk, not a mathematical impossibility
# (see the doc section for the full characterization and the failure-mode
# analysis for both directions this must guard).
# FM_BACKEND_HERDR_SUBMIT_POLLS (default 6): how many samples
# fm_backend_herdr_send_text_submit spreads across each Enter attempt's
# confirmation budget. Overridable for tests (a value of 1
# reproduces the old single-check-at-the-end timing exactly, for byte-for-byte
# call-count assertions).
FM_BACKEND_HERDR_SUBMIT_POLLS=${FM_BACKEND_HERDR_SUBMIT_POLLS:-6}
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=${FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP:-0.6}

fm_backend_herdr_submit_confirm_budget() {  # <caller-budget-seconds>
  awk -v b="${1:-0}" -v m="$FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP" 'BEGIN {
    b += 0
    m += 0
    if (b < 0) b = 0
    if (m < 0) m = 0
    if (m > b) b = m
    printf "%.4f", b
  }' 2>/dev/null || printf '%s' "${1:-0}"
}

fm_backend_herdr_wait_for_working() {  # <session> <pane_id> <budget-seconds> <polls>
  local session=$1 pane_id=$2 budget=$3 polls=${4:-1} i interval raw bs saw_idle=0
  case "$polls" in ''|*[!0-9]*|0) polls=1 ;; esac
  interval=$(awk -v b="$budget" -v p="$polls" 'BEGIN { d = p - 1; if (d < 1) d = 1; v = b / d; if (v < 0) v = 0; printf "%.4f", v }' 2>/dev/null)
  case "$interval" in ''|*[!0-9.]*) interval=0 ;; esac
  for ((i = 0; i < polls; i++)); do
    if [ "$polls" -eq 1 ] || [ "$i" -gt 0 ]; then
      sleep "$interval"
    fi
    raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane_id")
    bs=$(fm_backend_herdr_classify_submit_agent_status "$raw")
    case "$bs" in
      busy) printf 'busy'; return 0 ;;
      idle) saw_idle=1 ;;
    esac
  done
  if [ "$saw_idle" -eq 1 ]; then
    printf 'idle'
  else
    printf 'unknown'
  fi
}

# fm_backend_herdr_pane_for_tab: the root pane id for <tab_id> in <workspace_id>
# of <session>, via one pane list call filtered by tab_id (never assumes a
# tab-number/pane-number correspondence - herdr numbers them independently).
fm_backend_herdr_pane_for_tab() {  # <session> <workspace_id> <tab_id>
  local session=$1 wsid=$2 tab_id=$3 panes
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -r --arg tab "$tab_id" \
    '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | head -1
}

# fm_backend_herdr_resolve_bare_selector: private metadata-free fallback.
# Normal recorded routing never calls it. It scans every running named session
# and returns only one globally unique matching tab that owns exactly one pane.
# Any unreadable session, duplicate tab, empty tab, or multi-pane tab refuses.
fm_backend_herdr_resolve_bare_selector() {  # <name>
  local name=$1 raw sessions session tabs matches record wsid tab_id panes pane_ids pane_id
  local found=0 target=""
  raw=$(herdr session list --json 2>/dev/null) || {
    echo "error: herdr running-session inventory is unreadable" >&2
    return 1
  }
  sessions=$(printf '%s' "$raw" | jq -er '
    select((.sessions | type) == "array")
    | [.sessions[]? | select(.running == true)
       | .name | select(type == "string" and length > 0 and (test("[[:space:][:cntrl:]]") | not))]
    | select(length == (unique | length))
    | .[]
  ' 2>/dev/null) || {
    echo "error: herdr running-session inventory is ambiguous" >&2
    return 1
  }
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    tabs=$(fm_backend_herdr_cli "$session" tab list 2>/dev/null) || {
      echo "error: herdr tab inventory is unreadable in running session '$session'" >&2
      return 1
    }
    printf '%s' "$tabs" | jq -e '
      (.result.tabs | type) == "array"
      and all(.result.tabs[]?;
        (.tab_id | type) == "string" and (.tab_id | length) > 0
        and (.workspace_id | type) == "string" and (.workspace_id | length) > 0
        and (.label | type) == "string")
      and ([.result.tabs[]? | [.workspace_id,.tab_id]] | length)
          == ([.result.tabs[]? | [.workspace_id,.tab_id]] | unique | length)
    ' >/dev/null 2>&1 || {
      echo "error: herdr tab inventory is malformed in running session '$session'" >&2
      return 1
    }
    matches=$(printf '%s' "$tabs" | jq -r --arg want "$name" '
      .result.tabs[]? | select(.label == $want) | [.workspace_id,.tab_id] | @tsv
    ' 2>/dev/null) || return 1
    while IFS= read -r record; do
      [ -n "$record" ] || continue
      wsid=${record%%$'\t'*}
      tab_id=${record#*$'\t'}
      [ -n "$wsid" ] && [ -n "$tab_id" ] && [ "$tab_id" != "$record" ] || return 1
      panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || {
        echo "error: herdr pane inventory is unreadable for matching tab '$name'" >&2
        return 1
      }
      pane_ids=$(printf '%s' "$panes" | jq -er --arg workspace "$wsid" --arg tab "$tab_id" '
        select((.result.panes | type) == "array")
        | select(all(.result.panes[]?;
            (.pane_id | type) == "string" and (.pane_id | length) > 0
            and (.tab_id | type) == "string" and (.workspace_id | type) == "string"))
        | [.result.panes[]?
           | select(.workspace_id == $workspace and .tab_id == $tab)
           | .pane_id]
        | select(length == 1)
        | .[0]
      ' 2>/dev/null) || {
        echo "error: matching herdr tab '$name' does not own exactly one readable pane" >&2
        return 1
      }
      pane_id=$pane_ids
      found=$((found + 1))
      target="$session:$pane_id"
    done <<EOF
$matches
EOF
  done <<EOF
$sessions
EOF
  if [ "$found" -ne 1 ]; then
    echo "error: herdr tab '$name' is not globally unique across running sessions" >&2
    return 1
  fi
  printf '%s' "$target"
}

# Recovery discovery enumerates only exact home-local metadata tuples. Display
# labels corroborate the readable contract but never select an endpoint. This
# naturally lets a primary home enumerate several project workspaces and its
# exact second-mate parent records, while a marked second-mate home lists only
# the child task records stored in that home.
fm_backend_herdr_list_live() {  # <session>
  local session=$1 state="$FM_HOME/state" parent_meta meta backend kind id project label_home secondmate_home
  local workspace_label prior_workspace_label legacy_workspace_label recorded_workspace_label readable legacy workspace_list
  local live_workspace_label live_tab_label live_pane_label tuple seen="" lines=""
  fm_backend_herdr_metadata_validate_home "$state" || return 1
  parent_meta="$state/.herdr-parent.meta"
  if [ -e "$parent_meta" ] || [ -L "$parent_meta" ]; then
    fm_backend_herdr_metadata_validate_record "$parent_meta" || return 1
    [ "$(fm_backend_herdr_meta_field_exact "$parent_meta" backend 2>/dev/null)" = herdr ] || return 1
  fi
  workspace_list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$workspace_list" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1 || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    backend=$(fm_backend_herdr_meta_field_exact "$meta" backend 2>/dev/null) || continue
    [ "$backend" = herdr ] || continue
    fm_backend_herdr_metadata_load_tuple "$meta" || return 1
    [ "$FM_BACKEND_HERDR_META_SESSION" = "$session" ] || continue
    kind=$(fm_backend_herdr_meta_field_exact "$meta" kind 2>/dev/null) || return 1
    project=$(fm_backend_herdr_meta_field_exact "$meta" project 2>/dev/null) || return 1
    id=${meta##*/}; id=${id%.meta}
    label_home=$FM_HOME
    if [ "$kind" = secondmate ]; then
      secondmate_home=$(fm_backend_herdr_meta_field_exact "$meta" home 2>/dev/null) || return 1
      label_home=$secondmate_home
    fi
    readable=$(FM_HOME="$label_home" fm_backend_herdr_task_label "$id" "$kind") || return 1
    workspace_label=$(FM_HOME="$label_home" fm_backend_herdr_workspace_label "$project") || return 1
    prior_workspace_label=$(FM_HOME="$label_home" \
      fm_backend_herdr_workspace_prior_primary_label "$project" 2>/dev/null || true)
    legacy_workspace_label=$(FM_HOME="$label_home" fm_backend_herdr_workspace_legacy_label) || return 1
    recorded_workspace_label=$(fm_backend_herdr_meta_field_exact \
      "$meta" herdr_workspace_label 2>/dev/null || true)
    # Exact metadata may bind the strict projected child shape or the prior
    # <project> · primary spelling. Neither label can select a route without
    # this exact metadata tuple.
    if [ -n "$recorded_workspace_label" ]; then
      if [ "$recorded_workspace_label" = "$workspace_label" ] \
         || [ "$recorded_workspace_label" = "$legacy_workspace_label" ] \
         || { [ -n "$prior_workspace_label" ] \
           && [ "$recorded_workspace_label" = "$prior_workspace_label" ]; } \
         || printf '%s\n' "$recorded_workspace_label" \
           | grep -Eq '^└ .+ · p:[A-Za-z0-9_-]{22}$'; then
        workspace_label=$recorded_workspace_label
      else
        return 1
      fi
    fi
    legacy="fm-$id"
    tuple="${FM_BACKEND_HERDR_META_WORKSPACE}"$'\t'"${FM_BACKEND_HERDR_META_TAB}"$'\t'"${FM_BACKEND_HERDR_META_PANE}"
    printf '%s' "$seen" | grep -Fqx "$tuple" && {
      echo "error: duplicate local metadata records claim one herdr endpoint" >&2
      return 1
    }
    seen="${seen}${tuple}"$'\n'

    fm_backend_herdr_live_tuple_state "$session" "$FM_BACKEND_HERDR_META_WORKSPACE" \
      "$FM_BACKEND_HERDR_META_TAB" "$FM_BACKEND_HERDR_META_PANE" 0 "$workspace_list" || return 1
    case "$FM_BACKEND_HERDR_LIVE_TUPLE_STATE" in
      missing-workspace|missing-tab|missing-pane) continue ;;
      exact) ;;
      *) return 1 ;;
    esac
    live_workspace_label=$FM_BACKEND_HERDR_LIVE_WORKSPACE_LABEL
    live_tab_label=$FM_BACKEND_HERDR_LIVE_TAB_LABEL
    live_pane_label=$FM_BACKEND_HERDR_LIVE_PANE_LABEL
    fm_backend_herdr_metadata_label_matches "$meta" display_label "$readable" || return 1
    fm_backend_herdr_metadata_label_matches "$meta" herdr_workspace_label "$workspace_label" || return 1
    fm_backend_herdr_metadata_label_matches "$meta" herdr_tab_label "$readable" || return 1
    fm_backend_herdr_metadata_label_matches "$meta" herdr_pane_label "$readable" || return 1
    if grep -q '^herdr_workspace_label=' "$meta"; then
      [ "$live_workspace_label" = "$workspace_label" ] || return 1
    else
      [ "$live_workspace_label" = "$workspace_label" ] \
        || [ "$live_workspace_label" = "$legacy_workspace_label" ] \
        || { [ -n "$prior_workspace_label" ] \
          && [ "$live_workspace_label" = "$prior_workspace_label" ]; } || return 1
    fi
    if grep -q '^herdr_tab_label=' "$meta"; then
      [ "$live_tab_label" = "$readable" ] || return 1
    else
      [ "$live_tab_label" = "$readable" ] || [ "$live_tab_label" = "$legacy" ] || return 1
    fi
    if grep -q '^herdr_pane_label=' "$meta"; then
      [ "$live_pane_label" = "$readable" ] || return 1
    else
      [ -z "$live_pane_label" ] || [ "$live_pane_label" = "$readable" ] || [ "$live_pane_label" = "$legacy" ] || return 1
    fi
    lines="${lines}${session}:${FM_BACKEND_HERDR_META_PANE}"$'\t'"${readable}"$'\n'
  done
  printf '%s' "$lines"
}

# --- native event push: pane.agent_status_changed subscriber -----------------
#
# The push half of the immediate blocked-state escalation (AGENTS.md section 8,
# docs/herdr-backend.md "Native pane.agent_status_changed push escalation").
# fm_backend_herdr_wait_transition is the watcher's bounded wait primitive for
# herdr homes: instead of a blind sleep, it blocks on herdr's native event
# stream and returns the instant a subscribed pane transitions to `blocked`, so
# a crew waiting on the human wakes its supervisor sub-second instead of after
# the ~240s stale-pane wedge timer. Everything not `blocked` is streamed too
# (the policy, not the subscription, makes `blocked` the sole immediate action)
# so `working` edges clear the per-pane dedupe marker. Polling stays the
# permanent fail-closed backstop: below-capability, a connect/subscribe failure,
# or a missing reader all fall back to the caller sleeping the same budget.

# fm_backend_herdr_socket_path: the control-socket path for <session>, read from
# `herdr session list --json` (the default session's socket differs from a named
# session's - verified: default -> ~/.config/herdr/herdr.sock, named ->
# ~/.config/herdr/sessions/<name>/herdr.sock). Empty on any failure.
fm_backend_herdr_socket_path() {  # <session>
  local session=$1
  herdr session list --json 2>/dev/null \
    | jq -r --arg name "$session" '.sessions[]? | select(.name == $name) | .socket_path // empty' 2>/dev/null \
    | head -1
}

# fm_backend_herdr_events_capable: the version/capability gate for the event
# fast-path (report section 5c trigger 1). Fails closed to the poll loop unless
# ALL hold: herdr+jq present; the raw-socket reader available (python3, unless a
# reader override is configured); client protocol >= FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL;
# and both `events.subscribe` and `pane.agent_status_changed` present in `herdr
# api schema`. FM_BACKEND_HERDR_EVENTS_FORCE overrides the whole verdict for
# tests (1 = capable, 0 = incapable) without touching the real binary. The
# `api schema` read is ~220KB, so callers (the watcher) memoize this per session
# for a process lifetime rather than probing every poll.
fm_backend_herdr_events_capable() {  # <session>
  local session=$1 protocol schema
  case "${FM_BACKEND_HERDR_EVENTS_FORCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  fm_backend_herdr_tool_check || return 1
  if [ -z "${FM_BACKEND_HERDR_EVENT_READER:-}" ]; then
    command -v python3 >/dev/null 2>&1 || return 1
  fi
  protocol=$(herdr status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in ''|*[!0-9]*) return 1 ;; esac
  [ "$protocol" -ge "$FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL" ] || return 1
  schema=$(herdr api schema --json 2>/dev/null) || return 1
  printf '%s' "$schema" | grep -Fq 'events.subscribe' || return 1
  printf '%s' "$schema" | grep -Fq 'pane.agent_status_changed' || return 1
  return 0
}

# fm_backend_herdr_normalize_event: THE single normalize point (report section 5
# refinement: one backend transition shape, one parse point). Both the stream
# reader's projected lines AND the level-reconcile's `agent get` reads flow
# through here into the shared normalized-transition record. herdr's event
# carries no previous status and its stream is edge-triggered, so from_status is
# left empty; to_status drives the policy.
fm_backend_herdr_normalize_event() {  # <pane_id> <workspace_id> <agent_status> <agent>
  fm_transition_record "${1:-}" "${2:-}" "" "${3:-}" "${4:-}"
}

# fm_backend_herdr_event_reader_cmd: emit the reader argv (one word per line) for
# the raw-socket subscriber. Default: `python3 <this dir>/herdr-eventwait.py`.
# FM_BACKEND_HERDR_EVENT_READER overrides it with a whitespace-split command so
# tests can substitute a fake reader that replays canned stream lines.
fm_backend_herdr_event_reader_cmd() {
  local word
  if [ -n "${FM_BACKEND_HERDR_EVENT_READER:-}" ]; then
    for word in $FM_BACKEND_HERDR_EVENT_READER; do
      printf '%s\n' "$word"
    done
    return 0
  fi
  printf 'python3\n'
  printf '%s\n' "$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-eventwait.py"
}

# fm_backend_herdr_escalation_marker: the per-pane dedupe marker path for a
# <window> ("<session>:<pane_id>"), keyed identically to the watcher's
# .stale-<key> (tr ':/.' '___'), under <state_dir>.
fm_backend_herdr_escalation_marker() {  # <state_dir> <window>
  local state=$1 window=$2 key
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s/%s%s' "$state" "$FM_BACKEND_HERDR_ESCALATED_PREFIX" "$key"
}

# fm_backend_herdr_apply_transition: route one normalized record through the
# shared policy table, maintaining the per-pane dedupe marker under <state_dir>.
# On a fresh `actionable` (blocked) edge - policy actionable AND no marker yet -
# it prints the record on stdout and returns 0 (the caller stops and hands the
# record up). The caller commits the marker only after handling the record.
# `absorb` (working) clears the marker and
# returns 1. `defer`/`fallback`, and an already-marked `actionable`, return 1
# with no output. <session> reconstructs the window ("<session>:<pane_id>") for
# the marker key, matching the watcher's own key scheme.
fm_backend_herdr_apply_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id to action window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  to=$(fm_transition_to_status "$record")
  action=$(fm_transition_policy "$to")
  window="$session:$pane_id"
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  case "$action" in
    actionable)
      if [ ! -e "$marker" ]; then
        printf '%s' "$record"
        return 0
      fi
      ;;
    absorb)
      rm -f "$marker" 2>/dev/null || true
      ;;
  esac
  return 1
}

fm_backend_herdr_commit_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  window="$session:$pane_id"
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  : > "$marker"
}

fm_backend_herdr_clear_transition() {  # <state_dir> <window>
  local state=$1 window=$2 marker
  [ -n "$window" ] || return 0
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  rm -f "$marker" 2>/dev/null || true
}

# fm_backend_herdr_wait_transition: the bounded event wait. Blocks up to
# <timeout_secs> for one of <pane_window...> ("<session>:<pane_id>") to reach a
# fresh `blocked` edge, then prints the normalized record and returns 0.
# Returns 1 on a clean timeout (the reader ran the full budget, no fresh
# actionable edge - the caller has effectively already slept and just continues)
# and 2 when the event path is unusable (not capable, socket unresolved, reader
# failed to run/subscribe - the caller sleeps the budget itself, the fail-closed
# backstop). See the header block above for the full contract.
fm_backend_herdr_wait_transition() {  # <session> <timeout_secs> <state_dir> <pane_window...>
  local session=$1 timeout=$2 state=$3
  shift 3
  local windows=("$@")
  [ "${#windows[@]}" -gt 0 ] || return 2
  if [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_herdr_events_capable "$session" || return 2
  fi
  local sock
  sock=$(fm_backend_herdr_socket_path "$session")
  [ -n "$sock" ] || return 2

  # Map each window to its herdr pane id (strip the leading "<session>:").
  local w pane_id
  local pane_ids=()
  for w in "${windows[@]}"; do
    pane_id=${w#*:}
    if [ -z "$pane_id" ] || [ "$pane_id" = "$w" ]; then
      continue
    fi
    pane_ids+=("$pane_id")
  done
  [ "${#pane_ids[@]}" -gt 0 ] || return 2

  # Start the raw-socket reader and wait for its subscription acknowledgement
  # before level reconciliation, so edges occurring during reconciliation are
  # already buffered in the live stream.
  local reader=()
  while IFS= read -r w; do
    reader+=("$w")
  done < <(fm_backend_herdr_event_reader_cmd)
  [ "${#reader[@]}" -gt 0 ] || return 2

  local fifo_dir fifo reader_pid line ws status agent raw record hit rc=1 reader_rc=0
  fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-eventwait.XXXXXX") || return 2
  fifo="$fifo_dir/events"
  if ! mkfifo "$fifo" 2>/dev/null; then
    rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  "${reader[@]}" "$sock" "$timeout" "${pane_ids[@]}" > "$fifo" 2>/dev/null &
  reader_pid=$!
  if ! exec 9< "$fifo"; then
    kill "$reader_pid" 2>/dev/null || true
    wait "$reader_pid" 2>/dev/null || true
    rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  if ! IFS= read -r -u 9 line || [ "$line" != "@subscribed" ]; then
    rc=2
  fi

  # Level reconcile on (re)connect (report section 3d): a pane already `blocked`
  # during the gap since the last subscription is returned now, once, while
  # newer edges accumulate in the active stream. `working` panes clear their
  # marker here too.
  if [ "$rc" -ne 2 ]; then
    for w in "${windows[@]}"; do
      pane_id=${w#*:}
      if [ -z "$pane_id" ] || [ "$pane_id" = "$w" ]; then
        continue
      fi
      raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane_id")
      [ -n "$raw" ] || continue
      record=$(fm_backend_herdr_normalize_event "$pane_id" "" "$raw" "")
      if hit=$(fm_backend_herdr_apply_transition "$state" "$session" "$record"); then
        printf '%s' "$hit"
        rc=0
        break
      fi
    done
  fi

  # Drain stream edges until a fresh blocked edge or the timeout. The reader is
  # a subprocess of this call (NOT a second watcher), and is killed the instant
  # a blocked edge is found.
  # Split each raw projected line (pane_id\tworkspace_id\tagent_status\tagent)
  # with `cut`, NOT `IFS=$'\t' read`: a tab is IFS-whitespace, so `read` would
  # collapse an empty middle field (e.g. an absent workspace_id) and shift the
  # status into the wrong column. `cut` preserves empty fields.
  while [ "$rc" -eq 1 ] && IFS= read -r line <&9; do
    [ -n "$line" ] || continue
    pane_id=$(printf '%s' "$line" | cut -f1)
    ws=$(printf '%s' "$line" | cut -f2)
    status=$(printf '%s' "$line" | cut -f3)
    agent=$(printf '%s' "$line" | cut -f4)
    [ -n "$pane_id" ] || continue
    record=$(fm_backend_herdr_normalize_event "$pane_id" "$ws" "$status" "$agent")
    if hit=$(fm_backend_herdr_apply_transition "$state" "$session" "$record"); then
      printf '%s' "$hit"
      rc=0
      break
    fi
  done
  if [ "$rc" -eq 0 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  if [ "$rc" -eq 2 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  # No actionable edge: distinguish a clean full-budget wait (reader exit 0 ->
  # return 1, caller already waited) from a reader error (connect/subscribe
  # failure, exit non-zero -> return 2, caller sleeps and counts toward the
  # runtime-disable threshold).
  wait "$reader_pid" 2>/dev/null || reader_rc=$?
  exec 9<&-
  rm -rf "$fifo_dir" 2>/dev/null || true
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && return 2
  [ "$reader_rc" -eq 0 ] && return 1
  return 2
}
