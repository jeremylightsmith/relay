defmodule Schemas.RunnerRateLimit do
  @moduledoc """
  RE320 — why a runner has stopped claiming: it paused itself at a Claude usage limit. Embedded
  in `Schemas.Runner.rate_limit`; built only by `Schemas.Runner.normalize_rate_limit/1` from the
  heartbeat's `rate_limit` wire object, never cast from user input.

    * `window` — one of `Schemas.Runner.rate_limit_windows/0`
    * `utilization` — Claude's reported fraction of that window used; nil when Claude refused a
      call before the runner had a reading
    * `max` — the runner's configured limit for that window; nil for a refusal with no limit
    * `resets_at` — when the window resets, which is when the runner claims again
    * `reason` — one of `Schemas.Runner.rate_limit_reasons/0`
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field :window, :string
    field :utilization, :float
    field :max, :float
    field :resets_at, :utc_datetime
    field :reason, :string
  end
end
