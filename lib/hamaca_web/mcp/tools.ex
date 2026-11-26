defmodule HamacaWeb.Mcp.Tools do
  @moduledoc """
  The registry of MCP tools (RE519) — the one list `tools/list` advertises and `tools/call`
  dispatches against. Every tool is **read-only** in this slice (ADR 0015): nothing reachable from
  here approves, rejects, answers, moves, creates or comments.
  """

  alias HamacaWeb.Mcp.Tools.BoardStatus
  alias HamacaWeb.Mcp.Tools.GetCard
  alias HamacaWeb.Mcp.Tools.ListBoards
  alias HamacaWeb.Mcp.Tools.NeedsMe

  @tools [ListBoards, BoardStatus, NeedsMe, GetCard]

  @doc "Every tool module, in `tools/list` order."
  @spec all() :: [module()]
  def all, do: @tools

  @doc "The tool module named `name`, or `:error`."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) do
    case Enum.find(@tools, &(&1.name() == name)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  @doc "The `tools/list` entries."
  @spec list() :: [%{name: String.t(), description: String.t(), inputSchema: map()}]
  def list do
    for tool <- @tools, do: %{name: tool.name(), description: tool.description(), inputSchema: tool.input_schema()}
  end
end
