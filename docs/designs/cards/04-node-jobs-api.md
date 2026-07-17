# 04 — Node-job API: the server↔executor protocol

**Why.** The engine (Fly) and the agents (developer machine) are separated by ADR 0006's
brain/hands split. This is the contract between them — an extension of the existing
board-key REST API, not a parallel surface (ADR 0001).

**Scope.**

- Endpoints (board-key auth, like the rest of `/api`):
  - claim: an executor asks for the next node-job (long-poll or short-poll), advertising
    its capacity per isolation class; payload carries node type, rendered `run`, the
    isolation requirement (`shared_clean` / `exclusive`), and template vars — never
    worktree paths, which are the executor's own business.
  - logs: batched output lines per node-job (converge with the existing
    `POST /api/board/logs` / RLY-112 run-id attribution rather than adding a twin).
  - outcome: `{outcome, detail, git_sha, session_id}` with `outcome` from the closed set;
    completes the node-job and wakes the engine. `git_sha` anchors the code state;
    `session_id` (the `claude -p` session) lets a needs-input re-entry resume the agent's
    session instead of starting cold.
  - heartbeat: per-executor liveness (replaces today's `/api/board/heartbeat` usage);
    node-jobs on a dead executor become reclaimable after a timeout. **Backward compat is
    required**: the legacy watcher's bare-refs heartbeat must keep working — both runner
    generations run side by side until the last flow cuts over (W10), and heartbeat errors
    are swallowed client-side, so a breaking change would fail silently.
- **Agent-node outcome contract**: how a headless `claude -p` signals its result — an
  outcome JSON file the executor reads (plus "card went to needs_input" detection, as the
  runner does today). Documented in `docs/agent-integration.md`.
- **Edge-borne context**: a node's outcome `detail` is its return value; the job payload's
  prompt template may reference `{prior.detail}` (the node that routed here) and
  `{nodes.<id>.detail}` — this is how reviewer findings reach the implement re-entry, with
  no context store beyond the card.

**Out of scope.** The Python executor itself (05), dispatch decisions (02/03 own those).

**Acceptance criteria.**

1. A scripted fake executor (curl-level) can claim a job, stream logs, report each of the
   four outcomes, and the engine routes accordingly.
2. A job claimed by an executor that stops heartbeating is reclaimable by another.
3. Unknown outcome values are rejected (422). `mix precommit` passes.
