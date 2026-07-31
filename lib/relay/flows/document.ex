defmodule Relay.Flows.Document do
  @moduledoc """
  The canonical, round-trippable JSON document for a flow (RLY-241) — one shape used by the
  API's `GET`/`PUT /api/flows/:key`, by the shipped library files in `docs/designs/flows/*.json`,
  and by the Flow Editor's save path indirectly (both go through `Schemas.Flow.changeset/2`).

  Pure: no `Repo`, no board, no stage ids. The two things that need the database — resolving
  trigger stage NAMES to ids, and saving — stay in `Relay.Flows`.

  ## Sparse out, dense in

  `encode/1` omits a field that is `nil` or that equals its schema default
  (`expects_commits: false`). That is what keeps the three shipped files readable and keeps a
  diff of two documents meaningful.

  `decode/1` fills every node/edge field back in from the schema default. This matters more
  than it looks: `Relay.Flows.customized?/1` and `diff_from_default/1` compare library attrs
  against embedded structs field-by-field, so a *sparse* library map would compare unequal
  against a struct carrying `expects_commits: false` and flag every default flow as customized.

  Together these make **`decode ∘ encode` a fixed point**, so pull → push unchanged is a
  genuine no-op.

  String→atom conversion is driven by the schemas' own source functions
  (`Schemas.Flow.isolation_classes/0`, `Schemas.Flow.Node.types/0`,
  `Schemas.NodeExecution.outcomes/0`, `Schemas.Flow.Edge.when_values/0`) — never
  `String.to_atom/1`. An unrecognized value is an `{:error, message}`, not a new atom.
  """

  alias Schemas.Flow
  alias Schemas.NodeExecution
  alias Schemas.Stage

  @top_level ~w(key version enabled isolation trigger nodes edges)
  @trigger_keys ~w(pulls_from works_in lands_on)
  @trigger_fields [:pulls_from, :works_in, :lands_on]

  # Marks "the document did not carry this key" — distinct from "carried null".
  @absent :__absent__

  # ---------------------------------------------------------------- encode

  @doc """
  A flow as the canonical, JSON-ready document. Requires the trigger stage associations to be
  preloaded (`Relay.Flows.get_flow_with_stages/2` or `Relay.Flows.list_flows/1`); an unloaded
  association raises rather than silently emitting a triggerless document.
  """
  def encode(%Flow{} = flow) do
    %{
      "key" => flow.key,
      "version" => flow.version,
      "enabled" => flow.enabled,
      "isolation" => Atom.to_string(flow.isolation),
      "trigger" => %{
        "pulls_from" => stage_name(flow.pulls_from_stage),
        "works_in" => stage_name(flow.works_in_stage),
        "lands_on" => stage_name(flow.lands_on_stage)
      },
      "nodes" => Enum.map(flow.nodes || [], &sparse(&1, Flow.Node.fields(), %Flow.Node{})),
      "edges" => Enum.map(flow.edges || [], &sparse(&1, Flow.Edge.fields(), %Flow.Edge{}))
    }
  end

  defp stage_name(nil), do: nil
  defp stage_name(%Stage{name: name}), do: name

  defp stage_name(%Ecto.Association.NotLoaded{}) do
    raise ArgumentError,
          "Relay.Flows.Document.encode/1 requires the flow's trigger stages to be preloaded"
  end

  defp sparse(item, fields, defaults) do
    fields
    |> Enum.reject(fn field ->
      value = Map.get(item, field)
      is_nil(value) or value == Map.get(defaults, field)
    end)
    |> Map.new(fn field -> {Atom.to_string(field), json_value(Map.get(item, field))} end)
  end

  defp json_value(value) when is_atom(value) and not is_boolean(value), do: Atom.to_string(value)
  defp json_value(value), do: value

  # ---------------------------------------------------------------- decode

  @doc """
  A document as dense, changeset-ready attrs with the trigger as stage NAMES.

  Returns exactly the attr shape `Relay.Flows.DefaultLibrary.all/0` returns, which is already
  what `seed_default_flows!/1`, `customized?/1`, `diff_from_default/1` and `reset_to_default/1`
  consume — so the compile-time library path and the API push path share one decoder.

  `:key`, `:enabled`, `:version` and `:trigger` appear in the result ONLY when the document
  carries them: a push that doesn't mention `enabled` must not silently disarm a live flow.
  """
  def decode(doc) when is_map(doc) do
    with :ok <- reject_unknown(Map.keys(doc), @top_level, "top-level key"),
         {:ok, isolation} <- required_enum(doc, "isolation", Flow.isolation_classes()),
         {:ok, nodes} <- decode_list(doc, "nodes", &node_attrs/1),
         {:ok, edges} <- decode_list(doc, "edges", &edge_attrs/1),
         {:ok, trigger} <- decode_trigger(doc),
         {:ok, scalars} <- optional_scalars(doc) do
      {:ok,
       %{isolation: isolation, nodes: nodes, edges: edges}
       |> put_present(:key, scalars.key)
       |> put_present(:version, scalars.version)
       |> put_present(:enabled, scalars.enabled)
       |> put_present(:trigger, trigger)}
    end
  end

  def decode(_doc), do: {:error, "document must be a JSON object"}

  @doc "Like `decode/1` but raises — the compile-time library path, where a bad file is a build error."
  def decode!(doc) do
    case decode(doc) do
      {:ok, attrs} -> attrs
      {:error, reason} -> raise ArgumentError, "invalid flow document: #{reason}"
    end
  end

  defp optional_scalars(doc) do
    with {:ok, key} <- optional(doc, "key", &as_string/2),
         {:ok, enabled} <- optional(doc, "enabled", &as_boolean/2),
         {:ok, version} <- optional(doc, "version", &as_integer/2) do
      {:ok, %{key: key, enabled: enabled, version: version}}
    end
  end

  defp put_present(attrs, _field, @absent), do: attrs
  defp put_present(attrs, field, value), do: Map.put(attrs, field, value)

  defp optional(doc, key, caster) do
    case Map.fetch(doc, key) do
      :error -> {:ok, @absent}
      {:ok, value} -> caster.(value, key)
    end
  end

  defp as_string(value, _key) when is_binary(value), do: {:ok, value}
  defp as_string(_value, key), do: {:error, "#{key} must be a string"}

  defp as_boolean(value, _key) when is_boolean(value), do: {:ok, value}
  defp as_boolean(_value, key), do: {:error, "#{key} must be true or false"}

  defp as_integer(value, _key) when is_integer(value), do: {:ok, value}
  defp as_integer(_value, key), do: {:error, "#{key} must be an integer"}

  defp decode_trigger(doc) do
    case Map.fetch(doc, "trigger") do
      :error -> {:ok, @absent}
      {:ok, nil} -> {:ok, Map.new(@trigger_fields, &{&1, nil})}
      {:ok, trigger} when is_map(trigger) -> trigger_names(trigger)
      {:ok, _other} -> {:error, "trigger must be an object"}
    end
  end

  defp trigger_names(trigger) do
    with :ok <- reject_unknown(Map.keys(trigger), @trigger_keys, "trigger key") do
      Enum.reduce_while(@trigger_fields, {:ok, %{}}, &reduce_trigger_field(&1, &2, trigger))
    end
  end

  defp reduce_trigger_field(field, {:ok, acc}, trigger) do
    case Map.get(trigger, Atom.to_string(field)) do
      nil -> {:cont, {:ok, Map.put(acc, field, nil)}}
      name when is_binary(name) -> {:cont, {:ok, Map.put(acc, field, name)}}
      _other -> {:halt, {:error, "trigger.#{field} must be a stage name or null"}}
    end
  end

  defp decode_list(doc, key, caster) do
    case Map.get(doc, key, []) do
      items when is_list(items) -> reduce_items(items, key, caster)
      _other -> {:error, "#{key} must be an array"}
    end
  end

  defp reduce_items(items, key, caster) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case cast_item(item, caster, key, index) do
        {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp cast_item(item, caster, key, index) when is_map(item) do
    case caster.(item) do
      {:ok, attrs} -> {:ok, attrs}
      {:error, message} -> {:error, "#{key}[#{index}]: #{message}"}
    end
  end

  defp cast_item(_item, _caster, key, index), do: {:error, "#{key}[#{index}] must be an object"}

  defp node_attrs(node) do
    with :ok <- reject_unknown(Map.keys(node), field_names(Flow.Node.fields()), "node field"),
         {:ok, _key} <- required_string(node, "key"),
         {:ok, type} <- required_enum(node, "type", Flow.Node.types()) do
      {:ok, node |> dense(Flow.Node.fields(), %Flow.Node{}) |> Map.put(:type, type)}
    end
  end

  defp edge_attrs(edge) do
    with :ok <- reject_unknown(Map.keys(edge), field_names(Flow.Edge.fields()), "edge field"),
         {:ok, _from} <- required_string(edge, "from"),
         {:ok, _to} <- required_string(edge, "to"),
         {:ok, on} <- optional_enum(edge, "on", NodeExecution.outcomes()),
         {:ok, guard} <- optional_enum(edge, "when", Flow.Edge.when_values()) do
      {:ok, edge |> dense(Flow.Edge.fields(), %Flow.Edge{}) |> Map.merge(%{on: on, when: guard})}
    end
  end

  # Every field present: the document's value when given, else the schema's own default. An
  # explicit `null` counts as "not given" — JSON has two ways to say nothing, and a hand-edited
  # document that spells out `"expects_commits": null` must not store nil where the schema says
  # false (that would make `Flows.customized?/1` compare nil != false and flag the flow forever).
  defp dense(item, fields, defaults) do
    Map.new(fields, fn field ->
      {field, item |> Map.get(Atom.to_string(field)) |> default_if_nil(Map.get(defaults, field))}
    end)
  end

  defp default_if_nil(nil, default), do: default
  defp default_if_nil(value, _default), do: value

  defp field_names(fields), do: Enum.map(fields, &Atom.to_string/1)

  defp reject_unknown(keys, allowed, label) do
    case Enum.sort(keys -- allowed) do
      [] -> :ok
      extra -> {:error, "unknown #{label}: #{Enum.join(extra, ", ")}"}
    end
  end

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "#{key} is required"}
    end
  end

  defp required_enum(map, key, values) do
    case Map.get(map, key) do
      nil -> {:error, "#{key} is required"}
      value -> to_enum(value, key, values)
    end
  end

  defp optional_enum(map, key, values) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> to_enum(value, key, values)
    end
  end

  defp to_enum(value, key, values) when is_binary(value) do
    case Enum.find(values, &(Atom.to_string(&1) == value)) do
      nil -> {:error, ~s(#{key} "#{value}" is not one of: #{Enum.map_join(values, ", ", &to_string/1)})}
      atom -> {:ok, atom}
    end
  end

  defp to_enum(_value, key, _values), do: {:error, "#{key} must be a string"}
end
