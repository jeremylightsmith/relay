defmodule Schemas.SetupMachine do
  @moduledoc """
  One person's machine connected to a board (RE446, "connect a machine"): a per-machine setup run
  with that person's own board key. Its checklist is its own `Schemas.BoardSetupStep` rows (the
  ones carrying this `machine_id`); the board's own rows have `machine_id` nil. The board-wide
  steps and the interview / customize sub-steps are skipped (`Hamaca.Setup.connect_skips/0`).

  `api_key_id` is the step-3 key minted for this machine (nil once revoked); `host` and
  `runner_name` are recorded by the machine's step-6 heartbeat. All fields are programmatic,
  never cast from user input.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "setup_machines" do
    field :host, :string
    field :runner_name, :string

    belongs_to :board, Schemas.Board
    belongs_to :user, Schemas.User
    belongs_to :api_key, Schemas.ApiKey

    has_many :steps, Schemas.BoardSetupStep, foreign_key: :machine_id

    timestamps(type: :utc_datetime)
  end
end
