defmodule Schemas.Harness do
  @moduledoc """
  An agent CLI a board can run flow nodes on (RE433): a shell-style **command template** plus
  the CLI's closed list of `models`. `key` is the stable identifier a runner matches against its
  installed CLIs; it is derived from the name once by `Relay.Agents.create_harness/2` and never
  changes. `key` and `board_id` are set programmatically, never cast.

  A template is expanded by the runner: each `{placeholder}` (one of `placeholders/0`) is
  substituted, and an optional `[ … ]` segment is dropped whole when a placeholder inside it has
  no value. `command` must carry `{prompt}`; `resume_command` (nil = the CLI cannot resume) must
  carry `{prompt}` and `{session}`. `session_id_path` is a dot path (`.session_id`) into the
  CLI's JSON events naming the session to resume. `signed_in_check` is a command whose exit
  status says the CLI is signed in.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @placeholders ["prompt", "model", "worktree", "ref", "effort", "subagent", "session"]

  schema "harnesses" do
    field :key, :string
    field :name, :string
    field :command, :string
    field :models, {:array, :string}, default: []
    field :resume_command, :string
    field :session_id_path, :string
    field :signed_in_check, :string

    belongs_to :board, Schemas.Board

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "The closed set of `{placeholder}` names a command template may use — the ONE copy."
  @spec placeholders() :: [String.t()]
  def placeholders, do: @placeholders

  @doc """
  Validates a harness. `models` takes a list or a comma-separated string: each entry is trimmed,
  blanks dropped, and at least one unique entry is required.
  """
  def changeset(harness, attrs) do
    harness
    |> cast(normalize_models(attrs), [:name, :command, :models, :resume_command, :session_id_path, :signed_in_check])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :command])
    |> validate_models()
    |> validate_template(:command, ["prompt"])
    |> validate_template(:resume_command, ["prompt", "session"])
    |> validate_format(:session_id_path, ~r/\A(\.[A-Za-z0-9_]+)+\z/, message: "must be a dot path like .session_id")
    |> unique_constraint(:name, name: :harnesses_board_id_name_index, message: "is already used on this board")
    |> unique_constraint(:key, name: :harnesses_board_id_key_index)
  end

  defp normalize_models(attrs) do
    case fetch_models(attrs) do
      {key, value} when is_binary(value) -> Map.put(attrs, key, split_models(String.split(value, ",")))
      {key, value} when is_list(value) -> Map.put(attrs, key, split_models(value))
      _absent -> attrs
    end
  end

  defp fetch_models(attrs) do
    Enum.find_value(["models", :models], fn key -> if Map.has_key?(attrs, key), do: {key, Map.get(attrs, key)} end)
  end

  defp split_models(entries) do
    entries |> Enum.map(&(&1 |> to_string() |> String.trim())) |> Enum.reject(&(&1 == ""))
  end

  defp validate_models(changeset) do
    models = get_field(changeset, :models) || []
    duplicate = models |> Enum.frequencies() |> Enum.find_value(fn {m, n} -> if n > 1, do: m end)

    cond do
      models == [] -> add_error(changeset, :models, "can't be blank")
      duplicate -> add_error(changeset, :models, "has duplicate model #{inspect(duplicate)}")
      true -> changeset
    end
  end

  defp validate_template(changeset, field, required) do
    case get_field(changeset, field) do
      nil -> changeset
      template -> Enum.reduce(template_errors(template, required), changeset, &add_error(&2, field, &1))
    end
  end

  defp template_errors(template, required) do
    used = ~r/\{([^{}]*)\}/ |> Regex.scan(template, capture: :all_but_first) |> List.flatten()
    unknown = Enum.find(used, &(&1 not in @placeholders))
    missing = Enum.find(required, &(&1 not in used))

    Enum.reject(
      [
        missing && "must contain {#{missing}}",
        unknown && "unknown placeholder {#{unknown}}",
        if(balanced_segments?(template), do: nil, else: "has an unbalanced [ … ] segment")
      ],
      &is_nil/1
    )
  end

  # `[` opens an optional segment and `]` closes it; segments never nest.
  defp balanced_segments?(template) do
    template
    |> String.graphemes()
    |> Enum.reduce_while(false, fn
      "[", false -> {:cont, true}
      "[", true -> {:halt, :error}
      "]", true -> {:cont, false}
      "]", false -> {:halt, :error}
      _char, open? -> {:cont, open?}
    end)
    |> Kernel.==(false)
  end
end
