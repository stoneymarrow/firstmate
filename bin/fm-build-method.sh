#!/usr/bin/env bash
# Resolve the Build-only coding-method launch flags for one harness.
# Usage: fm-build-method.sh <harness> <task-type>
#   <task-type> is build or run. Only build activates the method; run prints
#   nothing and is the negative control that proves activation is not ambient.
# Prints the flags to insert into the launch command, with a trailing space, or
# nothing. Always exits 0: a Build that cannot reach the method still launches,
# and says why on stderr, because losing the worker is worse than losing the method.
#
# The method is stock Superpowers (github.com/obra/superpowers), never a fork or
# a copy. Each harness has its own stock activation, and both are session-scoped
# so the captain's own sessions keep the plugin off:
#   claude  --settings <build-session-settings.json>  enables the installed
#           superpowers@superpowers-dev plugin for this session only. The file is
#           deployed by dotfiles install.sh to $CLAUDE_CONFIG_DIR (default
#           ~/.claude); dotfiles owns its content.
#   pi      -e <checkout>  loads a stock Superpowers checkout as a temporary Pi
#           package for this session only. Upstream documents this exact command
#           for local development, alongside the durable
#           `pi install git:github.com/obra/superpowers`; firstmate uses the
#           session-scoped form so no spawn writes to the captain's Pi home.
#           The checkout path comes from FM_SUPERPOWERS_PI or, failing that,
#           config/superpowers-pi in the active firstmate home. It must contain
#           .pi/extensions/superpowers.ts, which is the stock Pi entry point;
#           a checkout without it predates Pi support and is refused.
# codex, opencode, grok and kimi have no wired activation here: upstream ships a
# Codex and an OpenCode path, but neither has been verified against firstmate's
# launch command, so this script stays silent rather than claiming coverage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

HARNESS=${1:-}
TASK_TYPE=${2:-run}
[ -n "$HARNESS" ] || { echo "error: usage: fm-build-method.sh <harness> <task-type>" >&2; exit 1; }

case "$TASK_TYPE" in
  build) ;;
  run) exit 0 ;;
  *) echo "error: task type must be build or run, not '$TASK_TYPE'" >&2; exit 1 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

case "$HARNESS" in
  claude)
    settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/build-session-settings.json"
    if [ ! -f "$settings" ]; then
      echo "warn: Build on claude cannot enable Superpowers: $settings is not deployed (dotfiles install.sh owns it)" >&2
      exit 0
    fi
    printf -- '--settings %s ' "$(shell_quote "$settings")"
    ;;
  pi)
    checkout=${FM_SUPERPOWERS_PI:-}
    if [ -z "$checkout" ] && [ -f "$FM_HOME/config/superpowers-pi" ]; then
      checkout=$(sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$FM_HOME/config/superpowers-pi" | head -1)
    fi
    if [ -z "$checkout" ]; then
      echo "warn: Build on pi cannot enable Superpowers: no checkout declared (set FM_SUPERPOWERS_PI or config/superpowers-pi)" >&2
      exit 0
    fi
    case "$checkout" in "~"/*) checkout="$HOME/${checkout#~/}" ;; esac
    if [ ! -f "$checkout/.pi/extensions/superpowers.ts" ]; then
      echo "warn: Build on pi cannot enable Superpowers: $checkout has no .pi/extensions/superpowers.ts (stock Pi support starts at Superpowers 6.x)" >&2
      exit 0
    fi
    printf -- '-e %s ' "$(shell_quote "$checkout")"
    ;;
esac
