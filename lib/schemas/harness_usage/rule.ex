defmodule Schemas.HarnessUsage.Rule do
  @moduledoc """
  The pure evaluator behind a harness's usage rule (RE436), mirrored line for line by `./relay`
  (`parse_rule_path`, `parse_rule_condition`, `read_rule_path`, `rule_holds`, `usage_reading`).
  Both pass the shared `usage_rule_cases` in `test/fixtures/runner_contract.json`.

  **Paths** are a jq subset: `.a.b.c`, with `[n]` indexing an array (`.a[0].b`). A missing value
  reads as nil. **Conditions** are `<path> == <literal>` or `<path> != <literal>`, optionally
  joined by ` and `; a literal is a JSON string, number, `true`, `false` or `null`. Equality is
  JSON equality: `1 == 1.0` holds, `true == 1` does not.

  Total by construction: any term in, an answer out — a malformed rule or line degrades to nil or
  false and never raises, because the runner applies these to every line a CLI prints.
  """

  @type path :: [String.t() | non_neg_integer()]
  @type reading :: %{
          windows: [%{label: String.t(), used_pct: float(), resets_at: pos_integer()}],
          refused_resets_at: pos_integer() | nil
        }

  @path_re ~r/\A(?:\.[A-Za-z0-9_]+(?:\[[0-9]+\])*)+\z/
  @segment_re ~r/\.([A-Za-z0-9_]+)|\[([0-9]+)\]/
  @path_char_re ~r/\A[A-Za-z0-9_.\[\]]+/
  @number_re ~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/
  @whitespace [?\s, ?\t, ?\n, ?\r]

  @doc "Parses a path into its keys and indexes, or `:error`."
  @spec parse_path(term()) :: {:ok, path()} | :error
  def parse_path(path) when is_binary(path) do
    if Regex.match?(@path_re, path) do
      {:ok, for([_ | groups] <- Regex.scan(@segment_re, path), do: segment(groups))}
    else
      :error
    end
  end

  def parse_path(_path), do: :error

  defp segment([key]), do: key
  defp segment(["", index]), do: String.to_integer(index)

  @doc "The value at `path` in `event`; nil when missing or when the path is invalid."
  @spec read(term(), term()) :: term()
  def read(event, path) do
    case parse_path(path) do
      {:ok, segments} -> walk(event, segments)
      :error -> nil
    end
  end

  defp walk(value, []), do: value
  defp walk(%{} = map, [key | rest]) when is_binary(key) and not is_struct(map), do: walk(Map.get(map, key), rest)

  defp walk(list, [index | rest]) when is_list(list) and is_integer(index) do
    case Enum.drop(list, index) do
      [value | _] -> walk(value, rest)
      [] -> nil
    end
  end

  defp walk(_value, _segments), do: nil

  @doc "Parses a condition into `{path, :eq | :ne, literal}` clauses, or `:error`."
  @spec parse_condition(term()) :: {:ok, [{path(), :eq | :ne, term()}]} | :error
  def parse_condition(condition) when is_binary(condition), do: clauses(skip_ws(condition), [])
  def parse_condition(_condition), do: :error

  defp clauses(input, acc) do
    with {:ok, path, rest} <- take_path(input),
         {:ok, op, rest} <- take_op(skip_ws(rest)),
         {:ok, literal, rest} <- take_literal(skip_ws(rest)) do
      acc = [{path, op, literal} | acc]

      case rest do
        "" -> {:ok, Enum.reverse(acc)}
        <<c, _::binary>> when c in @whitespace -> after_clause(skip_ws(rest), acc)
        _glued -> :error
      end
    end
  end

  defp after_clause("", acc), do: {:ok, Enum.reverse(acc)}

  defp after_clause(<<"and", c, rest::binary>>, acc) when c in @whitespace, do: clauses(skip_ws(rest), acc)

  defp after_clause(_rest, _acc), do: :error

  defp take_path(input) do
    with [token] <- Regex.run(@path_char_re, input),
         {:ok, path} <- parse_path(token) do
      {:ok, path, binary_part(input, byte_size(token), byte_size(input) - byte_size(token))}
    else
      _ -> :error
    end
  end

  defp take_op("==" <> rest), do: {:ok, :eq, rest}
  defp take_op("!=" <> rest), do: {:ok, :ne, rest}
  defp take_op(_input), do: :error

  defp take_literal(<<?", _::binary>> = input) do
    with {:ok, length} <- string_length(input, 1),
         {:ok, string} <- Jason.decode(binary_part(input, 0, length)) do
      {:ok, string, binary_part(input, length, byte_size(input) - length)}
    else
      _ -> :error
    end
  end

  defp take_literal(input) do
    {token, rest} = split_token(input, "")

    case token do
      "true" -> {:ok, true, rest}
      "false" -> {:ok, false, rest}
      "null" -> {:ok, nil, rest}
      _number -> number_literal(token, rest)
    end
  end

  defp number_literal(token, rest) do
    with true <- Regex.match?(@number_re, token),
         {:ok, number} <- Jason.decode(token) do
      {:ok, number, rest}
    else
      _ -> :error
    end
  end

  # The byte length of the JSON string literal opening `input`, closing quote included.
  defp string_length(input, at) when at >= byte_size(input), do: :error

  defp string_length(input, at) do
    case :binary.at(input, at) do
      ?\\ -> string_length(input, at + 2)
      ?" -> {:ok, at + 1}
      _char -> string_length(input, at + 1)
    end
  end

  defp split_token(<<c, _::binary>> = rest, acc) when c in @whitespace, do: {acc, rest}
  defp split_token(<<c, rest::binary>>, acc), do: split_token(rest, <<acc::binary, c>>)
  defp split_token("", acc), do: {acc, ""}

  defp skip_ws(<<c, rest::binary>>) when c in @whitespace, do: skip_ws(rest)
  defp skip_ws(input), do: input

  @doc "True when `event` meets every clause of `condition`; false for an invalid condition."
  @spec holds?(term(), term()) :: boolean()
  def holds?(event, condition) do
    case parse_condition(condition) do
      {:ok, clauses} -> Enum.all?(clauses, &clause_holds?(event, &1))
      :error -> false
    end
  end

  defp clause_holds?(event, {path, :eq, literal}), do: json_equal?(walk(event, path), literal)
  defp clause_holds?(event, {path, :ne, literal}), do: not json_equal?(walk(event, path), literal)

  # Booleans and nil are atoms, so `==` already keeps `true` apart from `1` while `1 == 1.0`.
  defp json_equal?(a, b), do: a == b

  @doc """
  The usage reading `event` carries under the wire-shaped rule `usage` (`Schemas.HarnessUsage.wire/1`),
  or nil when the line is not a reading. `now` (unix seconds) anchors a `seconds_from_now` reset.

  A line is a reading when it meets `match` (its windows are read, each omitted when its used or
  reset value is invalid) or `pause_now.when` (then `refused_resets_at` is `pause_now.resets_path`,
  else the latest window reset, else nil).
  """
  @spec reading(term(), term(), integer()) :: reading() | nil
  def reading(%{"source" => source} = usage, event, now) when source != "none" and is_integer(now) do
    pause_now = usage["pause_now"]
    matched = holds?(event, usage["match"])
    refused = is_map(pause_now) and holds?(event, pause_now["when"])

    if matched or refused do
      windows = if matched, do: windows(usage, event, now), else: []
      %{windows: windows, refused_resets_at: if(refused, do: refused_resets_at(usage, pause_now, event, now, windows))}
    end
  end

  def reading(_usage, _event, _now), do: nil

  defp windows(%{"windows" => windows} = usage, event, now) when is_list(windows) do
    for %{} = window <- windows,
        used_pct = used_pct(usage["used_unit"], read(event, window["used_path"])),
        resets_at = resets_at(usage["resets_unit"], read(event, window["resets_path"]), now),
        used_pct != nil and resets_at != nil,
        do: %{label: window["label"], used_pct: used_pct, resets_at: resets_at}
  end

  defp windows(_usage, _event, _now), do: []

  defp refused_resets_at(usage, pause_now, event, now, windows) do
    resets_at(usage["resets_unit"], read(event, pause_now["resets_path"]), now) ||
      windows |> Enum.map(& &1.resets_at) |> Enum.max(fn -> nil end)
  end

  defp used_pct("fraction", used) when is_number(used) and used >= 0, do: used * 100 / 1
  defp used_pct("percent", used) when is_number(used) and used >= 0, do: used / 1
  defp used_pct(_unit, _used), do: nil

  defp resets_at("unix", r, _now) when is_number(r) and r > 0, do: trunc(r)
  defp resets_at("seconds_from_now", r, now) when is_number(r) and r >= 0, do: now + trunc(r)
  defp resets_at(_unit, _r, _now), do: nil
end
