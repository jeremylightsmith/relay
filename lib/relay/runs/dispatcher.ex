defmodule Relay.Runs.Dispatcher do
  @moduledoc """
  The dispatch behaviour (ADR 0006 card 02): how the engine hands a
  node-job to whatever executes it, configured via
  `config :relay, :runs_dispatcher, module`. `shell` and `gate` nodes
  dispatch exactly like `agent` nodes — the executor is what knows how to
  run them; the engine only routes their outcomes (a gate only ever
  reports succeeded/failed).
  """

  @doc "Make a queued job available to an executor."
  @callback dispatch(Schemas.NodeJob.t()) :: :ok

  @doc "Best-effort cancel of in-flight work; the DB row is already :revoked."
  @callback revoke(Schemas.NodeJob.t()) :: :ok
end
