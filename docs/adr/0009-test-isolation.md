# ADR 0009 — Test isolation: process-tree dependencies and explicit sandbox ownership

## Status

Accepted

## Context

A test module that runs `async: false` is serialised against the whole suite, so every serial
module adds directly to wall-clock time. The intuitive explanation for a serial test is "the
code reads application env, so the test must `Application.put_env`, so it must be serial". When
this suite was measured, that turned out to be almost never the real reason. Two things were:

- **Spawned processes with no sandbox ownership.** `Hamaca.DataCase.setup_sandbox/1` starts the
  sandbox owner with `shared: not tags[:async]`. Under `async: false` (shared mode) any process in
  the VM may use the test's connection, which hides the fact that `RunServer`,
  `Scheduler.Server`, `Activity.LogSink`, `Activity.Pruner` and LiveView processes touch the
  database. Under `async: true` (manual mode) each of them needs explicit ownership or it raises
  `DBConnection.OwnershipError`.
- **Globally named singletons and global config.** An engine that names itself and its children
  with fixed atoms can't be started twice, and a test helper that writes application env to steer
  production code leaks that value into every concurrent test.

Dependency injection alone does not fix the first problem: a process with an injected name,
started with `start_supervised!`, and reading no application env still fails under async if it
has no sandbox ownership.

## Decision

Tests default to `async: true`. Two rules make that safe.

**Rule 1: no runtime mutation of global or application state to configure behaviour.**
`Application` env is read at boot or in `config/*.exs`. After that, configuration and
collaborators flow through the process tree, in this order of preference:

- **An argument** (`start_link` option or function parameter) when the caller already has the
  value. For example, `Hamaca.Push.Delivery.APNS.deliver/3` takes the APNs config as an argument,
  `deliver/2` reads it once at the boundary through `Hamaca.Push.config/0`, and the test passes
  its own config.
- **`Hamaca.Config`**, a thin seam over the `process_tree` library, for a value read deep in a
  call chain the test doesn't drive (for example `SchedulerSupervisor` reading
  `:runs_auto_start` from the reaper's sweep). A test `Process.put/2`s the value under its key.
  Production reads it with `Hamaca.Config.get/2` (app-env keys) or `Hamaca.Config.git_sha/0` (the
  OS-env `GIT_SHA`), which look in the calling process, then its `$ancestors`, then its
  `$callers`, and with nothing found fall back to `Application.get_env(:hamaca, key, default)` or
  `System.get_env("GIT_SHA")`. Production behaviour is unchanged.
  - **Always `cache: false`.** `ProcessTree`'s default caches a found value in every process it
    walked through, so a long-lived process would keep one test's value for the rest of the run.
    `Hamaca.Config` never reads without `cache: false`.
  - **`nil` means absent.** `ProcessTree` treats a stored `nil` as not found. To make a value
    explicitly unset, store `false`; `git_sha/0` turns a found `false` back into `nil`, while
    `get/2` returns it as `false`.
  - Only values tests actually vary go through the seam. Boot-time reads stay plain
    `Application.get_env/3`.

A test never calls `Application.put_env/3`, `delete_env` or `System.put_env` to steer production
code. The only place those may appear in `test/` is `test/test_helper.exs` (one-time suite setup).

*Sanctioned exception:* a genuinely process-global singleton whose whole purpose is to be shared
and which has no instance seam (for example the `HamacaWeb.ApiLog` ring buffer, the app-wide
`Activity.LogSink`, Swoosh's Local mailbox). A test that must own such a singleton stays
`async: false` with a comment naming the reason.

**Rule 2: any process the code under test spawns has explicit DB-sandbox ownership.** Shared mode
is the documented fallback, not the default. Two mechanisms, in this order:

- **`Sandbox.allow/3` from the test**, when the test holds the pid, through
  `Hamaca.DataCase.allow!/1`:

  ```elixir
  pruner = allow!(start_supervised!({Pruner, name: :"pruner_#{System.unique_integer([:positive])}"}))
  ```

- **`$callers` propagation**, when a supervisor severs the chain and the test never sees the
  pid. `DynamicSupervisor.start_child/2` gives the child the *supervisor's* `$callers`, not the
  caller's, so the caller passes its chain down and the child re-seeds it:

  ```elixir
  # caller side
  DynamicSupervisor.start_child(sup, {Child, callers: Hamaca.Runs.Instance.callers(), ...})

  # the child's init/1
  def init(opts) do
    Hamaca.Runs.Instance.adopt_callers(opts)
    ...
  end
  ```

  `$callers` is the standard OTP caller-tracking convention that `Task`, `Mox`, `Req.Test` and
  `Ecto.Adapters.SQL.Sandbox` already honour, so production code propagates caller identity
  rather than naming Ecto, sandboxes or tests. In production the `:callers` option is absent and
  `adopt_callers/1` does nothing. `Hamaca.Runs.ensure_server/2` → `RunServer`,
  `Hamaca.Runs.SchedulerSupervisor` → `Scheduler.Server`, and `Hamaca.Runs.Supervisor`'s
  `Listener`, `RunnerReaper` and boot-resume `Task` all do this.

One `$callers` / `$ancestors` chain carries both sandbox ownership and `Hamaca.Config` values, so
a child started on a test's behalf sees that test's connection and that test's config, and no
other test sees either.

The same chain routes **which engine instance** a process belongs to
(`Hamaca.Runs.Instance.current/0`). `Hamaca.DataCase.start_engine!/1` registers a per-test
registry, run supervisor, listener, reaper and capacity table under unique names, and every
process the engine spawns for that test finds them. With nothing registered (production),
`current/0` returns the default instance and every name is the fixed one.

Rule 1 alone does not make a test async; rule 2 is what lifts the serial constraint. Rule 1 is
what keeps the suite from re-acquiring cross-test coupling by another route.

## Consequences

- `async: false` is an exception that carries its reason. `test/hamaca/test_isolation_test.exs`
  enforces both rules statically: it fails on any app-env or OS-env write in `test/` outside
  `test/test_helper.exs`, and on any non-browser module that runs `async: false` without a `#`
  comment directly above the `use` line or an explanation in its `@moduledoc`. Browser tests
  (`test/hamaca_web/browser/`) run serially by design and are outside that check.
- Every engine process that can be started on a caller's behalf accepts `:callers`. A new one
  must too, or it is invisible to the sandbox under async.
- `Hamaca.Runs` resolves its process names through `Instance.current/0` (a `Registry` lookup)
  instead of compile-time atoms. In production it resolves to the same names.
- `Hamaca.Runs.Capacity`'s ETS table is per instance, so one test can't read or wipe another's
  capacity.
- **`Sandbox.allow/3` cannot make an app-wide singleton async.** It binds a pid to exactly one
  connection. When two async tests `allow!` the same global process, the second gets
  `{:already, :allowed}` and the process stays on the first test's connection, failing silently
  (for `Activity.LogSink`, a missing broadcast). A shared singleton needs an instance seam to go
  async; `allow!` is not a substitute for one.
- **Known limitation: the `Listener` firehose is process-global.** Each engine instance has its
  own names but not its own event topic: `Hamaca.Runs.Listener.init/1` subscribes to
  `Hamaca.Events.subscribe_firehose/0`, which has no per-instance variant. The `Listener` that
  `start_engine!/1` gives a test therefore receives every concurrent test's card events and
  reconciles them on its own sandbox connection. That is harmless when a test's cards are its own
  (a foreign reconcile is a no-op), but a test that counts how often the engine reacted, or stops
  the tree mid-flight, races. `test/hamaca/runs/runner_reaper_test.exs` and
  `test/hamaca_web/live/board_settings_flow_preflight_test.exs` stay `async: false` for this
  reason. **If a new engine test flakes with events it never produced, this is why.**
- When a test reads a VM-global counter or setting, look for the process-local question it was
  really asking before making it serial.

## Alternatives considered

**A `:sandbox_owner` option on each engine child.** The same seam, but it names Ecto, sandboxes
and tests inside production code. `$callers` expresses the same thing as caller identity, which
is a legitimate OTP concern that `DBConnection`, `Mox` and `Req.Test` already honour.

**Leaving the engine tests serial.** The speed gain alone was modest, but the global-name and
`put_env` coupling is a correctness hazard regardless of speed: it is why two engine tests could
never run together, and it is the shape most likely to produce a mysterious cross-test failure as
the suite grows.

## Open questions

- How should the `Listener` be isolated per engine instance: a per-instance firehose topic, or a
  `start_engine!(listener: false)` option for tests that don't need one? Until one exists, the two
  modules above stay serial.
