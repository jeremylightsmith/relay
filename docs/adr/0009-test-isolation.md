# ADR 0009 — Test isolation: process-tree dependencies and explicit sandbox ownership

## Status

Proposed (2026-08-05)

## Context

19% of this suite's test modules (48 of 248) run `async: false`, serialising them against
everything else. On the branch that produced this ADR, `mix test --exclude browser` measured:

| | |
|---|---|
| Test modules | 248 |
| `async: false` modules | 48 (43 non-browser + 5 `test/relay_web/browser/`) |
| Baseline wall-clock | **24.8s = 18.6s async + 6.2s sync** |

The obvious hypothesis was that production code reads mutable application env
(`Application.get_env`), so tests must `Application.put_env`, so they must be serial.
**Measurement disproved it.** Flipping all 43 non-browser modules to `async: true` and changing
nothing else produced 20.1s and 254 failures across 28 files:

- 2615 × `DBConnection.OwnershipError`
- 210 × `RuntimeError — {:already_started, Relay.Runs.Supervisor}`
- 16 × exits
- **0** caused by application-env collisions

Only two files called `Application.put_env` at all, and both already passed as `async: true` with
zero changes.

The actual causes were two:

**(a) No sandbox ownership for spawned processes.** `Relay.DataCase.setup_sandbox/1` starts the
owner with `shared: not tags[:async]`. `async: false` ⇒ shared mode ⇒ *any* process in the VM may
use the test's connection, which is what silently let `RunServer`, `Scheduler.Server`,
`Activity.LogSink`, `Activity.Pruner` and LiveView processes reach the database. `async: true` ⇒
manual mode ⇒ each such process needs explicit ownership. There was not one `Sandbox.allow/3` call
in the entire suite.

**(b) Globally-named singletons.** `Relay.Runs.Supervisor` named itself `__MODULE__` and hard-named
its children `Relay.Runs.Registry` and `Relay.Runs.RunSupervisor`; `Relay.Runs` reached for both by
literal atom. Two async tests both starting the engine raced the name. Alongside it,
`Relay.Runs.FakeDispatcher.register/1` (test support) set `:runs_dispatcher` and
`:runs_fake_dispatcher_pid` in application env — genuine global mutation, read back by
`Relay.Runs.dispatcher/0`, so under async one test's dispatch notifications would be delivered to
another test's pid.

Dependency injection alone is demonstrably **not** sufficient. `test/relay/activity/pruner_test.exs`
already used the injected-name + `start_supervised!` pattern and still failed under async; one
test-only `Sandbox.allow/3` line fixed it with no production change.

## Decision

Two rules.

**Rule 1 — no runtime mutation of global or application state to configure behaviour.**
`Application` env is read at boot or in `config/*.exs`. After that, configuration and collaborators
flow through the process tree: `start_link` options, function arguments, or a process-scoped
context. A test never calls `Application.put_env/3` to steer production code.

*Sanctioned exception:* a boot-time-only read that no test mutates (e.g.
`Relay.Runs.engine_opts/0`, `Relay.Push.config/0`), and a genuinely process-global singleton whose
whole purpose is to be shared and which has no instance seam (e.g. `RelayWeb.ApiLog`, the app-wide
in-memory API ring buffer read by `RelayWeb.Admin.ApiLive`). A test that must own such a singleton
stays `async: false` **with a comment naming this exception**.

**Rule 2 — any process the code under test spawns must have explicit DB-sandbox ownership.**
Shared mode (`async: false`) is the documented fallback, not the default. Two mechanisms, in this
order of preference:

- **`Sandbox.allow/3` from the test**, when the test holds the pid. Use
  `Relay.DataCase.allow!/1`:

  ```elixir
  pruner = allow!(start_supervised!({Pruner, name: :"pruner_#{System.unique_integer([:positive])}"}))
  ```

- **`$callers` propagation**, when a `DynamicSupervisor` (or any supervisor) severs the chain and
  the test never sees the pid. The caller passes the chain down; the child re-seeds it:

  ```elixir
  # caller side
  DynamicSupervisor.start_child(sup, {Child, callers: [self() | Process.get(:"$callers", [])], ...})

  # child's init/1 — the entire seam
  def init(opts) do
    Relay.Runs.Instance.adopt_callers(opts)
    ...
  end
  ```

  `$callers` is the standard OTP/Elixir caller-tracking convention — what `Task` sets
  automatically and what `Mox`, `Req.Test` and `Ecto.Adapters.SQL.Sandbox` all honour — so
  production code propagates *caller identity*, a legitimate OTP concern, rather than naming Ecto,
  sandboxes or tests. In production the `:callers` option is absent and `adopt_callers/1` is a
  no-op.

**Rule 1 alone does not make a test async.** `pruner_test` is the cautionary case: it followed
rule 1 to the letter — injected name, `start_supervised!`, no application env — and still failed
under async, because the pruner process had no sandbox ownership. Rule 2 is the one that actually
lifts the serial constraint; rule 1 is what keeps the suite from re-acquiring cross-test coupling
by another route.

### The worked example for rule 1 — `Relay.Push`

Before: `Relay.Push.Delivery.APNS` read `Application.get_env(:relay, Relay.Push)` at call time, so
`apns_test.exs` had to `Application.put_env/3` in `setup` and restore it in `on_exit`.

```elixir
# before — apns.ex
def deliver(token, payload) do
  config = apns_config()          # Application.get_env(:relay, Push)[:apns]
  ...
end

# before — apns_test.exs
setup do
  previous = Application.get_env(:relay, Push)
  Application.put_env(:relay, Push, Keyword.put(previous, :apns, key: test_key_pem(), ...))
  on_exit(fn -> Application.put_env(:relay, Push, previous) end)
end
```

After: the app-env read moves to one boundary function, and the value is threaded as an argument.
The test passes its own config and mutates nothing.

```elixir
# after — apns.ex
def deliver(token, payload), do: deliver(token, payload, Push.config().apns)
def deliver(token, payload, apns_config) when is_list(apns_config), do: ...

# after — apns_test.exs
setup do
  %{apns: [key: test_key_pem(), key_id: "ABC1234567", ...]}
end

test "...", %{apns: apns} do
  assert :ok = APNS.deliver("device-token-xyz", @payload, apns)
end
```

### The worked example for rule 2 — the runs engine

`Relay.Runs.start_run/2` starts a `RunServer` through `DynamicSupervisor.start_child/2`. Verified
empirically: the child's `$callers` contains the *supervisor's* pid, not the caller's, and any
`Relay.Repo` call from it raises `DBConnection.OwnershipError`. `Relay.Runs.ensure_server/2` now
passes `callers: Relay.Runs.Instance.callers()` into the child spec and `RunServer.init/1` calls
`Relay.Runs.Instance.adopt_callers/1`. The same treatment applies to
`Relay.Runs.SchedulerSupervisor.ensure_started/2` → `Relay.Runs.Scheduler.Server`, and to
`Relay.Runs.Supervisor`'s own `Listener`, `ExecutorReaper` and boot-resume `Task` children.

The same `$callers` walk also routes *which engine instance* a process belongs to
(`Relay.Runs.Instance.current/0`), so a test can `start_engine!/0` its own tree under unique names
and every process the engine spawns on its behalf finds it. With nothing registered — production —
`current/0` returns the default instance and every name is exactly what it was before.

## Consequences

- Tests default to `async: true`. `async: false` becomes a documented exception carrying a
  one-line reason.
- `Relay.Runs` gained one indirection (`Instance.current/0`, a `Registry.lookup` per resolution)
  on paths that previously used compile-time atoms. It resolves to the same atoms in production.
- Every engine process that can be started on a caller's behalf now accepts `:callers`. New ones
  must do the same or they will be invisible to the sandbox under async.
- `Relay.Runs.Capacity`'s ETS table is resolved per instance rather than being a single named
  table, so a test's capacity can no longer be read or wiped by a concurrent test. `reset/0` is
  gone; a fresh instance starts with an empty table.
- **Known limitation — the `Listener` firehose is still process-global.** Rule 2 gave every engine
  its own names, but not its own event topic: `Relay.Runs.Listener.init/1` subscribes to
  `Relay.Events.subscribe_firehose/0`, which has no per-instance variant. So the `Listener` that
  `Relay.DataCase.start_engine!/1` hands a test receives **every concurrent test's** card events and
  reconciles them on **its own** sandbox connection. 24 async modules call `start_engine!/1` and
  carry this; they are green on the measured seed matrix because their cards are unique per test and
  a reconcile for a foreign card is a no-op, but it is a latent cross-test coupling, not an isolated
  one. Two modules provably lost that bet and stay `async: false` with in-file blocker comments —
  `test/relay/runs/executor_reaper_test.exs` and
  `test/relay_web/live/board_settings_flow_preflight_test.exs` — which is why this ADR's async
  conversion is **partially unmet**: those two were flipped, raced, and reverted. Closing it needs
  either a per-instance firehose topic or a `start_engine!(listener: false)` option; both are
  follow-up work, not part of this change. **If a new engine test flakes with events it never
  produced, this is why.**
- Wall-clock, `mix test --exclude browser`:
  - **before: 24.8s (18.6s async + 6.2s sync)**
  - **after: 19.9s (19.8s async + 0.1s sync)**, green on seeds 1, 424242 and 999 plus three
    randomised runs. The 0.1s sync tail is `test/support/data_case_test.exs` (reaches
    `Sandbox.allow/3`'s `:not_found` branch on purpose), `test/relay/runs/executor_reaper_test.exs`
    and `test/relay_web/live/board_settings_flow_preflight_test.exs` (the still-open
    global-firehose-vs-per-instance-`Listener` gap), `test/relay_web/story_map_filter_test.exs`
    (its own atom-count race), and the two `RelayWeb.ApiLog` modules — each carries its own
    ADR-0009-sanctioned reason comment.

## Alternatives considered

**A `:sandbox_owner` option on each engine child.** Equivalent seam, but it names Ecto, sandboxes
and tests inside production code. `$callers` expresses the same thing as caller identity — a
legitimate OTP concern — and is already honoured by `DBConnection`, `Mox` and `Req.Test`, so it
costs one line and buys three integrations.

**Leaving the engine tests serial.** The measured ceiling is ~4.7s (19% of wall-clock), which is
not on its own compelling. It was done anyway because the global-name and `put_env` coupling is a
correctness hazard independent of speed: it is why two engine tests could never run together, and
it is the shape most likely to produce a mysterious cross-test failure as the suite grows.
