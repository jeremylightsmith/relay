defmodule HamacaWeb.Mcp.Tool do
  @moduledoc """
  One MCP tool (RE519). `HamacaWeb.Mcp.Tools` lists the implementations; `HamacaWeb.Mcp.Server`
  advertises them on `tools/list` and dispatches `tools/call` to `call/2`.

  `call/2` acts as `user` (membership is the only access rule) and returns markdown for the model
  to relay. `{:error, sentence}` is a reply the model should read back to the human — it becomes
  `isError: true` with the sentence as the text, not a protocol error.
  """

  alias Schemas.User

  @doc "The tool's name on the wire, e.g. `\"board_status\"`."
  @callback name() :: String.t()

  @doc "Written for the model: when to use the tool, and how to reply."
  @callback description() :: String.t()

  @doc "The JSON Schema (`type: \"object\"`) of the tool's arguments."
  @callback input_schema() :: map()

  @callback call(User.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
end
