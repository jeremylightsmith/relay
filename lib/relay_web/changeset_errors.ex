defmodule RelayWeb.ChangesetErrors do
  @moduledoc """
  Flattens `Ecto.Changeset` errors into plain strings, including `cast_embed`
  errors.

  `Ecto.Changeset.traverse_errors/2` returns `%{field => [msg]}` for a flat
  changeset but `%{field => [%{nested => [msg]}]}` for an embed, so any renderer
  that assumes the flat shape raises on a schema with embeds. `Schemas.Flow`
  casts `:nodes`/`:edges` as embeds, and a second copy of this walk that only
  handled the flat shape turned every node-level graph error into a 500
  (RLY-241) — so the walk lives here once, and both the API fallback controller
  and the flow editor read it.
  """

  @doc """
  Every error as a field-qualified string — `"max_retries must be greater than 0"`
  at the top level, `"nodes max_retries must be greater than 0"` inside an embed.
  """
  def messages(%Ecto.Changeset{} = changeset) do
    changeset
    |> pairs()
    |> Enum.map(fn {path, msg} -> Enum.join(path ++ [msg], " ") end)
    |> Enum.uniq()
  end

  @doc "Every error as a bare message, with no field names — for UI that labels its own fields."
  def leaf_messages(%Ecto.Changeset{} = changeset) do
    changeset
    |> pairs()
    |> Enum.map(fn {_path, msg} -> msg end)
    |> Enum.uniq()
  end

  # One walk down to the leaves, carrying the field path that got there.
  defp pairs(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> walk([])
  end

  defp walk(errors, path) when is_map(errors),
    do: Enum.flat_map(errors, fn {field, value} -> walk(value, path ++ [to_string(field)]) end)

  defp walk(errors, path) when is_list(errors), do: Enum.flat_map(errors, &walk(&1, path))
  defp walk(msg, path) when is_binary(msg), do: [{path, msg}]

  # Substitute only the `%{placeholders}` the message actually spells out. Folding over `opts`
  # instead would call `to_string/1` on EVERY opt value, and a failed enum cast carries
  # `type: {:parameterized, {Ecto.Enum, %{...}}}` — a tuple, which has no String.Chars impl and
  # raises. That is how `PATCH /api/cards/:ref` with a bogus status 500s instead of 400ing.
  defp interpolate({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
