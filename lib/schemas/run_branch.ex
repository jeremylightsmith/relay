defmodule Schemas.RunBranch do
  @moduledoc """
  One branch of one region entry (RE437): a `fan_out` fires every outgoing edge at once, and each
  edge starts a branch. A row is keyed by the `fan_out` **execution** that opened the region
  (`fan_out_execution_id`) and the branch key (`branch`, the fan-out edge's `to`), so a region
  re-entered by a foreach lap or a `fan_in` loop-back gets a fresh set of rows.

  `state` walks `queued → running → ended` (`states/0`); `:parked` is a branch waiting on a human
  while its siblings keep running. `current_node` is the branch node in flight (nil once ended);
  the run's own `current_node` stays the `fan_out` key while the region is open. `outcome` and
  `detail` are what the `fan_in` joins (`Relay.Runs.Engine.join/1`): set when the branch ends,
  and left nil when a cancel or close ends it. All fields programmatic, never cast.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @states [:queued, :running, :parked, :ended]

  schema "run_branches" do
    field :branch, :string
    field :position, :integer
    field :state, Ecto.Enum, values: @states
    field :current_node, :string
    field :outcome, Ecto.Enum, values: [:succeeded, :failed]
    field :detail, :string

    belongs_to :run, Schemas.Run
    belongs_to :fan_out_execution, Schemas.NodeExecution

    timestamps(type: :utc_datetime)
  end

  @doc "The closed set of branch states, in lifecycle order."
  @spec states() :: [:queued | :running | :parked | :ended]
  def states, do: @states

  @doc "The states of a branch that has not ended — every state but `:ended`."
  @spec open_states() :: [:queued | :running | :parked]
  def open_states, do: @states -- [:ended]

  @doc "The closed set of branch outcomes the `fan_in` joins."
  @spec outcomes() :: [:succeeded | :failed]
  def outcomes, do: Ecto.Enum.values(__MODULE__, :outcome)

  @doc "Validates a programmatically-built branch row."
  def changeset(branch) do
    branch
    |> change()
    |> validate_required([:run_id, :fan_out_execution_id, :branch, :position, :state])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:fan_out_execution_id)
    |> unique_constraint([:fan_out_execution_id, :branch])
  end
end
