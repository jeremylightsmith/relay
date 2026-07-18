defmodule Schemas.Executor do
  @moduledoc """
  A durable executor registration (ADR 0006 card 04): the developer machine
  that pulls node-jobs. Keyed uniquely on `{board_id, name}` and refreshed on
  every claim / executor heartbeat. `capacity` is the last-advertised free
  capacity per isolation class, a STRING-keyed map like
  `%{"shared_clean" => 3, "exclusive" => 1}`. `last_heartbeat` drives reclaim:
  an executor silent past `max(60s, 2 × interval)` is stale and its in-flight
  jobs are recovered. All fields are set programmatically by `Relay.Runs`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "executors" do
    field :name, :string
    field :host, :string
    field :interval, :integer, default: 30
    field :capacity, :map, default: %{}
    field :last_heartbeat, :utc_datetime

    belongs_to :board, Schemas.Board

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built executor row."
  def changeset(executor, attrs) do
    executor
    |> cast(attrs, [:board_id, :name, :host, :interval, :capacity, :last_heartbeat])
    |> validate_required([:board_id, :name, :last_heartbeat])
    |> foreign_key_constraint(:board_id)
    |> unique_constraint([:board_id, :name], name: :executors_board_id_name_index)
  end
end
