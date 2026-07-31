defmodule RelayWeb.Api.FlowController do
  @moduledoc """
  Read and write a board's flow definitions as canonical documents (RLY-241) — the read surface
  `relay doctor` needs, and the write half the seed/adopt/refactor reconcile engine needs.
  """
  use RelayWeb, :controller

  alias Relay.Flows

  action_fallback RelayWeb.Api.FallbackController

  def index(conn, _params) do
    render(conn, :index, flows: Flows.list_flows(conn.assigns.current_board))
  end

  def show(conn, %{"key" => key}) do
    case Flows.get_flow_with_stages(conn.assigns.current_board, key) do
      nil -> {:error, :not_found}
      flow -> render(conn, :show, flow: flow)
    end
  end

  # The document is read from `conn.body_params`, NOT from `params`: Phoenix merges path params
  # over body params, so `params["key"]` is always the path key and a body/path key disagreement
  # would be invisible.
  def update(conn, %{"key" => key}) do
    case Flows.upsert_from_document(conn.assigns.current_board, key, conn.body_params) do
      {:ok, :created, flow} -> conn |> put_status(:created) |> render(:show, flow: flow)
      {:ok, :updated, flow} -> render(conn, :show, flow: flow)
      {:error, reason} -> {:error, reason}
    end
  end
end
