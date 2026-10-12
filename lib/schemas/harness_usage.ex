defmodule Schemas.HarnessUsage do
  @moduledoc """
  A harness's **usage rule** (RE436), embedded on `Schemas.Harness` as `usage`: how the runner
  reads that CLI's usage and when it pauses the harness. Board-stored, so a new CLI's limits are a
  setting rather than a runner release.

  - `source` — where readings come from: `"output"` (the job's own stream), `"command"` (a
    background `command` run every `interval_min` minutes) or `"none"` (no usage tracking).
  - `match` — the condition (`Schemas.HarnessUsage.Rule`) a line must meet to be a reading.
  - `windows` — what a reading carries, each converted by `used_unit` and `resets_unit`.
  - `pause_now` — an optional condition meaning "refused right now".
  - `recheck` — how a paused, idle harness is re-checked.

  `wire/1` is the string-keyed shape the runner reads off `GET /api/harnesses`; `./relay` mirrors
  the evaluator and the closed sets below, pinned by `test/fixtures/runner_contract.json`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Schemas.HarnessUsage.PauseNow
  alias Schemas.HarnessUsage.Recheck
  alias Schemas.HarnessUsage.Rule
  alias Schemas.HarnessUsage.Window

  @sources ["output", "command", "none"]
  @used_units ["fraction", "percent"]
  @resets_units ["unix", "seconds_from_now"]

  @condition_message ~s(is not a condition like .type == "x")
  @path_message "is not a path like .a.b"

  @primary_key false
  embedded_schema do
    field :source, :string, default: "none"
    field :match, :string
    field :command, :string
    field :interval_min, :integer
    field :used_unit, :string, default: "fraction"
    field :resets_unit, :string, default: "unix"

    embeds_many :windows, Window, on_replace: :delete
    embeds_one :pause_now, PauseNow, on_replace: :delete
    embeds_one :recheck, Recheck, on_replace: :update
  end

  @type t :: %__MODULE__{}

  @doc "Where a harness's usage readings come from — the ONE copy (`./relay`: `USAGE_SOURCES`)."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "How a window's used value is expressed — the ONE copy (`./relay`: `USAGE_USED_UNITS`)."
  @spec used_units() :: [String.t()]
  def used_units, do: @used_units

  @doc "How a window's reset value is expressed — the ONE copy (`./relay`: `USAGE_RESETS_UNITS`)."
  @spec resets_units() :: [String.t()]
  def resets_units, do: @resets_units

  @doc """
  Validates a usage rule. `models` is the harness's current model list, which `recheck.model`
  must be one of. A `pause_now` whose `when` is blank is dropped. Windows are cast with
  `windows_sort` / `windows_drop` so a form can add and remove them.
  """
  @spec changeset(t(), map(), [String.t()]) :: Ecto.Changeset.t()
  def changeset(usage, attrs, models) do
    usage
    |> cast(drop_blank_pause_now(attrs), [:source, :match, :command, :interval_min, :used_unit, :resets_unit])
    |> cast_embed(:windows, with: &Window.changeset/2, sort_param: :windows_sort, drop_param: :windows_drop)
    |> cast_embed(:pause_now, with: &PauseNow.changeset/2)
    |> cast_embed(:recheck, with: &Recheck.changeset(&1, &2, models))
    |> validate_required([:source])
    |> validate_inclusion(:source, @sources)
    |> validate_tracked()
    |> validate_command()
  end

  @doc "Adds `\"#{@path_message}\"` to `field` when its value is not a `Rule` path."
  @spec validate_path(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_path(changeset, field) do
    validate_change(changeset, field, fn ^field, path ->
      if Rule.parse_path(path) == :error, do: [{field, @path_message}], else: []
    end)
  end

  @doc "Adds `#{inspect(@condition_message)}` to `field` when its value is not a `Rule` condition."
  @spec validate_condition(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_condition(changeset, field) do
    validate_change(changeset, field, fn ^field, condition ->
      if Rule.parse_condition(condition) == :error, do: [{field, @condition_message}], else: []
    end)
  end

  # A rule that reads usage at all needs a match, a window, valid units and a recheck.
  defp validate_tracked(changeset) do
    if get_field(changeset, :source) == "none" do
      changeset
    else
      changeset
      |> validate_required([:match, :used_unit, :resets_unit])
      |> validate_condition(:match)
      |> validate_inclusion(:used_unit, @used_units)
      |> validate_inclusion(:resets_unit, @resets_units)
      |> validate_windows()
      |> validate_recheck_present()
    end
  end

  defp validate_command(changeset) do
    if get_field(changeset, :source) == "command" do
      changeset
      |> validate_required([:command, :interval_min])
      |> validate_number(:interval_min, greater_than: 0)
    else
      changeset
    end
  end

  defp validate_windows(changeset) do
    labels = for %Window{label: label} <- get_field(changeset, :windows), do: label
    duplicate = labels |> Enum.reject(&is_nil/1) |> Enum.frequencies() |> Enum.find_value(&duplicate_label/1)

    cond do
      labels == [] -> add_error(changeset, :windows, "needs at least one window")
      duplicate -> add_error(changeset, :windows, "has duplicate window #{inspect(duplicate)}")
      true -> changeset
    end
  end

  defp duplicate_label({label, n}) when n > 1, do: label
  defp duplicate_label(_entry), do: nil

  defp validate_recheck_present(changeset) do
    if get_field(changeset, :recheck), do: changeset, else: add_error(changeset, :recheck, "can't be blank")
  end

  defp drop_blank_pause_now(attrs) do
    Enum.reduce(["pause_now", :pause_now], attrs, &drop_blank_pause_now/2)
  end

  defp drop_blank_pause_now(key, %{} = attrs) do
    case attrs do
      %{^key => %{} = pause_now} -> if blank_when?(pause_now), do: Map.put(attrs, key, nil), else: attrs
      _other -> attrs
    end
  end

  defp blank_when?(pause_now) do
    case Map.get(pause_now, "when", Map.get(pause_now, :when)) do
      value when is_binary(value) -> String.trim(value) == ""
      nil -> true
      _other -> false
    end
  end

  @doc """
  The rule as the runner reads it off `GET /api/harnesses` — string keys throughout. nil (a
  harness saved before RE436) is the wire of an empty rule, whose source is `"none"`.
  """
  @spec wire(t() | nil) :: map()
  def wire(nil), do: wire(%__MODULE__{})

  def wire(%__MODULE__{} = usage) do
    %{
      "source" => usage.source,
      "match" => usage.match,
      "command" => usage.command,
      "interval_min" => usage.interval_min,
      "used_unit" => usage.used_unit,
      "resets_unit" => usage.resets_unit,
      "windows" =>
        Enum.map(usage.windows, fn %Window{} = w ->
          %{"label" => w.label, "used_path" => w.used_path, "resets_path" => w.resets_path, "pause_at" => w.pause_at}
        end),
      "pause_now" => usage.pause_now && %{"when" => usage.pause_now.when, "resets_path" => usage.pause_now.resets_path},
      "recheck" => usage.recheck && %{"model" => usage.recheck.model, "interval_min" => usage.recheck.interval_min}
    }
  end
end
