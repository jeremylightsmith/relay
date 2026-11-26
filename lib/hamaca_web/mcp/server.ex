defmodule HamacaWeb.Mcp.Server do
  @moduledoc """
  The MCP server's JSON-RPC 2.0 dispatch (RE519, ADR 0015), in streamable HTTP's **stateless
  JSON mode**: one request in, one JSON reply out — no SSE stream and no `Mcp-Session-Id`.

  `handle/2` takes the decoded message and the authenticated user and returns `{:reply, map}`, or
  `:accepted` for a notification (a message with no `"id"`). Methods: `initialize`, `ping`,
  `tools/list` and `tools/call` (dispatched through `HamacaWeb.Mcp.Tools`).
  """

  alias HamacaWeb.Mcp.Tools
  alias Schemas.User

  @protocol_versions ["2025-11-25", "2025-06-18", "2025-03-26"]

  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602

  @doc "The MCP protocol versions this server speaks, newest first."
  @spec protocol_versions() :: [String.t()]
  def protocol_versions, do: @protocol_versions

  @doc "The JSON-RPC error code for a message that is not a JSON-RPC request object."
  @spec invalid_request_code() :: integer()
  def invalid_request_code, do: @invalid_request

  @spec handle(map(), User.t()) :: {:reply, map()} | :accepted
  def handle(%{"jsonrpc" => "2.0", "method" => method} = message, %User{} = user) when is_binary(method) do
    case Map.fetch(message, "id") do
      {:ok, id} -> {:reply, respond(id, dispatch(method, Map.get(message, "params"), user))}
      :error -> :accepted
    end
  end

  def handle(_message, _user), do: {:reply, respond(nil, {:error, @invalid_request, "Invalid Request"})}

  defp dispatch("initialize", params, _user) do
    requested = params_map(params)["protocolVersion"]
    version = if requested in @protocol_versions, do: requested, else: hd(@protocol_versions)

    {:ok, %{protocolVersion: version, capabilities: %{tools: %{}}, serverInfo: %{name: "Hamaca", version: app_version()}}}
  end

  defp dispatch("ping", _params, _user), do: {:ok, %{}}

  defp dispatch("tools/list", _params, _user), do: {:ok, %{tools: Tools.list()}}

  defp dispatch("tools/call", params, user) do
    params = params_map(params)

    with name when is_binary(name) <- params["name"],
         {:ok, tool} <- Tools.fetch(name) do
      case tool.call(user, params_map(params["arguments"])) do
        {:ok, text} -> {:ok, tool_result(text, false)}
        {:error, sentence} -> {:ok, tool_result(sentence, true)}
      end
    else
      _unknown -> {:error, @invalid_params, "Unknown tool: #{inspect(params["name"])}"}
    end
  end

  defp dispatch(method, _params, _user), do: {:error, @method_not_found, "Method not found: #{method}"}

  defp tool_result(text, error?), do: %{content: [%{type: "text", text: text}], isError: error?}

  defp params_map(params) when is_map(params), do: params
  defp params_map(_params), do: %{}

  defp respond(id, {:ok, result}), do: %{jsonrpc: "2.0", id: id, result: result}
  defp respond(id, {:error, code, message}), do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp app_version, do: :hamaca |> Application.spec(:vsn) |> to_string()
end
