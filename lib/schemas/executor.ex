defmodule Schemas.Executor do
  @moduledoc """
  A durable executor registration (ADR 0006 card 04): the developer machine
  that pulls node-jobs. Keyed uniquely on `{board_id, name}` and refreshed on
  every claim / executor heartbeat. `capacity` is the last-advertised free
  capacity per isolation class, a STRING-keyed map like
  `%{"shared_clean" => 3, "exclusive" => 1}`. `last_heartbeat` drives reclaim:
  an executor silent past `max(60s, 2 × interval)` is stale and its in-flight
  jobs are recovered. `capabilities` is the last-reported inventory of what this
  executor can resolve by name — `%{"agents" => [...], "skills" => [...]}` — or
  `nil` when it has never reported one (RLY-182). All fields are set
  programmatically by `Relay.Runs`.

  `version` is the `EXECUTOR_VERSION` the running `bin/relay` declares (RLY-184); `nil` means
  an executor predating that card, which `Relay.Runs.executor_outdated?/1` treats as behind.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "executors" do
    field :name, :string
    field :host, :string
    field :interval, :integer, default: 30
    field :capacity, :map, default: %{}
    # No default: nil means "never reported its inventory" and is deliberately distinct
    # from %{} ("reported, and empty"). Preflight branches on that difference.
    field :capabilities, :map
    field :version, :integer
    field :last_heartbeat, :utc_datetime

    belongs_to :board, Schemas.Board

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built executor row."
  def changeset(executor, attrs) do
    executor
    |> cast(attrs, [:board_id, :name, :host, :interval, :capacity, :capabilities, :version, :last_heartbeat])
    |> validate_required([:board_id, :name, :last_heartbeat])
    |> foreign_key_constraint(:board_id)
    |> unique_constraint([:board_id, :name], name: :executors_board_id_name_index)
  end
end
