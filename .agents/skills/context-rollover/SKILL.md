---
name: context-rollover
description: >-
  Agent-only procedure for clearing a context-rollover decision.
  Use on any wake whose status event carries the key context-rollover - the external context sensor's hard handoff, the handoff actuator's offer, or a stalled-rollover report.
  Owns the retire-and-succeed action, its refusals, and the partial-rollover outcome.
user-invocable: false
metadata:
  internal: true
---

# context-rollover

Load this the moment a status event carries the decision key `context-rollover`, whatever verb or wording surrounds it.
Three producers open that key, and all three mean the same thing:

- the external context sensor's hard handoff, when a worker crossed its hard context ceiling and every further tool call is denied;
- the handoff actuator's `offer`, when a worker wrote its envelope and asked for a successor;
- `bin/fm-rollover.sh audit`, when a rollover that started never finished.

The event is firstmate's to clear because nothing inside a stopped window can start its own successor.
A worker at its hard ceiling cannot spawn, cannot read, and cannot investigate; it can only write the envelope and stop.
Leaving the event unhandled strands the task: the window reports nothing more, and the work sits in a copy no live worker holds.

## The action

    bin/fm-rollover.sh status <id>     # what is open, on which copy
    bin/fm-rollover.sh run <id>        # retire the stopped session, start one successor on the same copy

`run` is the whole procedure.
It refuses unless the task's own status stream still carries an open `context-rollover` decision, retires the stopped session, and launches one successor on the predecessor's preserved copy through `bin/fm-spawn.sh --adopt-worktree`.
The successor keeps the same task identity, the same recorded profile unless you override it, and the same original brief, reached through a successor brief that tells it to restate from the envelope first.
Read the script's `--help` for the exact flags, the durable record it writes, and its refusals.

A refusal is a stop-and-investigate result, never something to work around.
`run` refuses while the preserved copy cannot be proven intact, and it refuses to start a successor while the stopped session is still alive, because two workers must never hold one copy.
Never pass a rollover through a plain spawn instead: an ordinary spawn allocates a fresh copy and would split one task across two of them, abandoning the predecessor's uncommitted work.

## When the rollover only half happens

`run` exits non-zero and reopens the `context-rollover` decision when the session was retired but no successor took the task.
That is a real blocker, not a retry: the preserved copy is intact and unheld, so investigate why the launch refused before trying again.
`bin/fm-rollover.sh audit` finds the same failure later, for a rollover that opened and never reached a successor - run it when a heartbeat wake reviews the fleet.

## Reporting

Routine success is not captain-facing.
A rollover that worked is one worker replacing another on the same task; report nothing and carry on supervising.
Escalate only a failure, using `AGENTS.md` section 9 wording: the worker on <task> ran out of room and the replacement could not pick it up; the work so far is saved in its own copy and nothing is lost, but the task is stopped until <concrete blocker> is cleared.
Never surface the decision key, the status line, the copy path, or the retire-and-relaunch mechanics.
