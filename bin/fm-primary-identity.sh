#!/usr/bin/env bash
# Canonical active-home identity predicate for Firstmate PRIMARY behavior.
#
# Tracked Firstmate hooks are present in the primary checkout, secondmate homes,
# and disposable work/scout checkouts that work on Firstmate itself. Environment
# overrides deliberately point those disposable agents at the active fleet home,
# so git-dir/git-common-dir cannot decide which checkout owns primary behavior:
# a Treehouse pool checkout is a standalone clone and reports equal git dirs.
#
# The sole authority is physical path identity. A primary adapter may act only
# when the checkout that supplied its code is the explicit active FM_HOME. The
# main primary and each secondmate own session satisfy that equality; a linked
# task worktree and a standalone pool clone do not. FM_ROOT_OVERRIDE never
# supplies this identity because it is operational plumbing and may be inherited
# by a child process.
#
# Usage:
#   fm-primary-identity.sh [--code-root <dir>] [--require]
#
# Exit 0 means this checkout is the active primary home. Exit 1 means inert.
# --require emits one actionable error and exits 3 when the check is inert.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 1
DEFAULT_CODE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 1
CODE_ROOT=$DEFAULT_CODE_ROOT
REQUIRE=0

usage() {
  cat <<'EOF'
Usage: fm-primary-identity.sh [--code-root <dir>] [--require]

Returns 0 only when the physical checkout that supplied Firstmate code is the
explicit active FM_HOME. Use --require for fleet-primary entrypoints; it prints
an error and exits 3 instead of silently acting from a work/scout checkout.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --code-root)
      [ "$#" -gt 1 ] || { usage >&2; exit 2; }
      CODE_ROOT=$2
      shift 2
      ;;
    --code-root=*)
      CODE_ROOT=${1#--code-root=}
      shift
      ;;
    --require)
      REQUIRE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

identity_error() {
  [ "$REQUIRE" -eq 1 ] || return 0
  printf '%s\n' "error: refusing fleet-primary behavior from a checkout that is not the active FM_HOME (code root: ${CODE_ROOT:-unknown}; FM_HOME: ${FM_HOME:-unset})" >&2
}

inactive_exit() {
  identity_error
  if [ "$REQUIRE" -eq 1 ]; then
    exit 3
  fi
  exit 1
}

# Test-only escape hatch. Production sessions must carry an explicit FM_HOME so
# a standalone pool clone can never infer primary authority from its own path.
if [ "${FM_PRIMARY_IDENTITY_BYPASS:-}" = 1 ]; then
  exit 0
fi

[ -n "${FM_HOME:-}" ] || inactive_exit

CODE_ROOT=$(CDPATH='' cd -- "$CODE_ROOT" 2>/dev/null && pwd -P) || inactive_exit
ACTIVE_HOME=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || inactive_exit
GIT_TOP=$(git -C "$CODE_ROOT" rev-parse --show-toplevel 2>/dev/null) || inactive_exit
GIT_TOP=$(CDPATH='' cd -- "$GIT_TOP" 2>/dev/null && pwd -P) || inactive_exit

[ -f "$CODE_ROOT/AGENTS.md" ] && [ -d "$CODE_ROOT/bin" ] && [ "$CODE_ROOT" = "$GIT_TOP" ] && [ "$CODE_ROOT" = "$ACTIVE_HOME" ] && exit 0
inactive_exit
