# 05 — `bin/relay` executor mode

**Why.** ADR 0006 demotes the runner from orchestrator to hands: claim a node-job, run it
in the right worktree, stream output, report a typed outcome. Smaller than today's watcher.

**Scope.**

- `relay execute` subcommand: claim loop against the 04 API; runs `shell` steps and
  `claude -p` agent steps (reusing the existing streaming, worktree pool, ensure/reset
  machinery); writes back logs + outcome; heartbeats.
- The executor owns the isolation mapping: it translates each job's requirement
  (`shared_clean` / `exclusive`) onto its local worktree pools and advertises its capacity
  per class when claiming — pool layout and concurrency are configured here, not in flows.
- Reads the agent-node outcome contract (04) after each `claude -p`; detects the
  needs-input case exactly as `work()` does today. Honors a cancel signal from the server
  (job revoked mid-run when a human claims the card).
- Legacy `relay watch` keeps working unchanged — both modes coexist until 08/09 finish the
  migration.

**Out of scope.** Any dispatch/WIP logic (server-side now), removing legacy watch.

**Acceptance criteria.**

1. Against a live server, `relay execute` drains queued node-jobs: shell and agent steps
   run in the named worktree with live streamed output visible on the server.
2. Killing the executor mid-job → the job is reclaimed and re-run cleanly (worktree reset
   still salvages leftovers via stash).
3. `bin/test_relay.py` covers claim/execute/report; existing tests still pass.
