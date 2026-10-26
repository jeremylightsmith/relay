defmodule Schemas.BoardSetupStep do
  @moduledoc """
  One step of a board's setup checklist (RE443): a row per `(board_id, step)`, where `step` is a
  catalog id from `Hamaca.Setup.steps/0` (`"1"`…`"7"`, and `"5.1"`…`"5.8"` under step 5). A
  connected machine's checklist (RE446) is a row per `(machine_id, step)` on the same board; the
  board's own rows have `machine_id` nil.

  `status` is the step's state — the ONE closed set is `statuses/0`. The checklist is strictly
  sequential: one top-level step is current (`current_statuses/0`) at a time and every step after
  it is `:pending`. `evidence` is the line the board shows once a step ticks, `error` what a
  `:failed` step says, and `data` the step's facts (e.g. step 1's template, step 3's `key_id` —
  never a raw token). All fields are programmatic, never cast from user input.
  """

  use Ecto.Schema

  @type status :: :pending | :active | :waiting | :done | :failed | :skipped
  @type t :: %__MODULE__{}

  schema "board_setup_steps" do
    field :step, :string
    field :status, Ecto.Enum, values: [:pending, :active, :waiting, :done, :failed, :skipped]
    field :reached_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :evidence, :string
    field :error, :string
    field :data, :map, default: %{}

    belongs_to :board, Schemas.Board
    belongs_to :machine, Schemas.SetupMachine

    timestamps(type: :utc_datetime)
  end

  @doc "The closed set of setup-step statuses — the ONE list, in lifecycle order."
  @spec statuses() :: [status()]
  def statuses, do: Ecto.Enum.values(__MODULE__, :status)

  @doc "The statuses of the one step the checklist is on: active, waiting or failed."
  @spec current_statuses() :: [status()]
  def current_statuses, do: [:active, :waiting, :failed]

  @doc "The statuses of a step that is behind the user: done or skipped."
  @spec finished_statuses() :: [status()]
  def finished_statuses, do: [:done, :skipped]
end
