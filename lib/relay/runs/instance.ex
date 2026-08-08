defmodule Relay.Runs.Instance do
  @moduledoc """
  Which engine tree does this process belong to? (ADR 0009 rule 2.)

  The runs engine used to name its Registry, its run `DynamicSupervisor` and its capacity table
  with literal module atoms, and to read its dispatcher out of application env. That made exactly
  one engine possible per VM, which is why two tests could never drive the engine at the same
  time. This module replaces the literals with a lookup:

    * a process **registers** an instance for itself (`register/1`) — in practice, a test, via
      `Relay.DataCase.start_engine!/0`;
    * any process **resolves** the instance by walking `[self() | Process.get(:"$callers", [])]`
      (`current/0`) and falls back to `default/0` when nothing is registered.

  **In production nothing is ever registered**, so `current/0` returns `default/0` and every name
  is the same literal atom the engine used before. That is the property `instance_test.exs` pins
  first.

  `$callers` is the standard OTP/Elixir caller-tracking convention — what `Task` sets
  automatically and what `Mox`, `Req.Test` and `Ecto.Adapters.SQL.Sandbox` all honour. A
  `DynamicSupervisor.start_child/2` **severs** it (the child's `$callers` names the supervisor,
  not the caller), so the engine re-seeds it explicitly: the caller passes
  `callers: Relay.Runs.Instance.callers()` into the child spec and the child's `init/1` calls
  `adopt_callers/1`. That single seam gives the child both its Ecto sandbox connection and its
  engine instance. With no `:callers` option — production — `adopt_callers/1` does nothing.
  """

  # No `use Boundary`: this module belongs to the `Relay.Runs` sub-boundary declared in
  # `lib/relay.ex`, like `Relay.Runs.Capacity`. Nothing outside `Relay.Runs` calls it except
  # `Relay.DataCase` and `Relay.Runs.FakeDispatcher`, both of which are `check: [out: false]`, so
  # it needs no export.

  alias Relay.Runs.Capacity

  @registry Relay.Runs.InstanceRegistry

  @typedoc "The names and collaborators one engine tree runs under."
  @type t :: %{
          registry: atom(),
          run_supervisor: atom(),
          capacity_table: atom(),
          dispatcher: module(),
          dispatcher_pid: pid() | nil
        }

  @doc "The application-wide engine instance — what production always resolves to."
  @spec default() :: t()
  def default do
    %{
      registry: Relay.Runs.Registry,
      run_supervisor: Relay.Runs.RunSupervisor,
      capacity_table: Capacity.default_table(),
      dispatcher: Application.get_env(:relay, :runs_dispatcher, Relay.Runs.NoopDispatcher),
      dispatcher_pid: nil
    }
  end

  @doc """
  The instance this process belongs to: the overrides registered by the nearest process in
  `callers/0`, merged over `default/0`. Returns `default/0` when nothing is registered.
  """
  @spec current() :: t()
  def current do
    case overrides() do
      nil -> default()
      overrides -> Map.merge(default(), overrides)
    end
  end

  @doc """
  Registers (or merges into) instance overrides for the **calling** process. The registration is
  held in a `Registry` keyed by that pid, so it is released automatically when the process exits —
  a test needs no `on_exit` cleanup.
  """
  @spec register(map()) :: :ok
  def register(overrides) when is_map(overrides) do
    case Registry.register(@registry, self(), overrides) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_registered, _pid}} ->
        {_new, _old} = Registry.update_value(@registry, self(), &Map.merge(&1, overrides))
        :ok
    end
  end

  @doc "The caller chain to hand to a child that a supervisor is about to sever."
  @spec callers() :: [pid()]
  def callers, do: [self() | Process.get(:"$callers", [])]

  @doc """
  Re-seeds `$callers` from `opts[:callers]`. The entire seam: call it first thing in the `init/1`
  of any engine process that a supervisor starts on a caller's behalf. A no-op when the option is
  absent, which is always the case in production.
  """
  @spec adopt_callers(keyword()) :: :ok
  def adopt_callers(opts) do
    case Keyword.get(opts, :callers) do
      nil -> :ok
      callers when is_list(callers) -> Process.put(:"$callers", callers)
    end

    :ok
  end

  defp overrides do
    Enum.find_value(callers(), fn pid ->
      case Registry.lookup(@registry, pid) do
        [{_owner, overrides}] -> overrides
        [] -> nil
      end
    end)
  end
end
