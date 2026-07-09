defmodule Relay.CLI do
  @moduledoc """
  Relay's terminal client (MMF 10). Talks to the MMF 09 REST API over HTTP
  (`Req`), configured by `RELAY_URL` + `RELAY_API_KEY`. Each public command
  returns `{:ok, output}` or `{:error, message}` so `Mix.Tasks.Relay` can
  print and set the exit status. Not a context — never calls `Relay.*`.
  """

  use Boundary, deps: []

  @doc "Issues an authenticated request; returns the decoded body or an error string."
  def request(method, path, body \\ nil) do
    with {:ok, url} <- env("RELAY_URL"),
         {:ok, key} <- env("RELAY_API_KEY") do
      req = Req.new([base_url: url, auth: {:bearer, key}] ++ Application.get_env(:relay, :cli_req_options, []))
      send_request(req, method, path, body)
    end
  end

  @doc "The board summary: stages with their cards."
  def board(opts) do
    with {:ok, board} <- request(:get, "/api/board") do
      {:ok, render(opts, board, format_board(board))}
    end
  end

  @doc "A single card with its description + timeline."
  def card(ref, opts) do
    with {:ok, %{"data" => card}} <- request(:get, "/api/cards/#{ref}") do
      {:ok, render(opts, card, format_card(card))}
    end
  end

  @doc """
  The next card the agent should work: an AI-owned card first, otherwise an
  unclaimed card sitting in an AI-owned stage (not done).
  """
  def pull(opts) do
    with {:ok, board} <- request(:get, "/api/board") do
      stage_owner = Map.new(board["stages"], &{&1["id"], &1["owner"]})
      cards = board["cards"]

      pick =
        Enum.find(cards, &(&1["active_owner"] == "ai")) ||
          Enum.find(cards, fn c ->
            c["active_owner"] == nil and stage_owner[c["stage_id"]] == "ai" and c["status"] != "done"
          end)

      case pick do
        nil -> {:ok, render(opts, nil, "No card to pull.")}
        card -> {:ok, render(opts, card, format_card_line(card))}
      end
    end
  end

  @doc "Posts a comment (as the agent) on the card."
  def comment(ref, body, opts) do
    with {:ok, %{"data" => entry}} <- request(:post, "/api/cards/#{ref}/comments", %{body: body}) do
      {:ok, render(opts, entry, "#{ref}: comment posted")}
    end
  end

  @doc "Moves the card to the stage named `stage_name` (resolved on the board)."
  def move(ref, stage_name, opts) do
    with {:ok, board} <- request(:get, "/api/board"),
         %{"id" => stage_id} <- Enum.find(board["stages"], &(&1["name"] == stage_name)) || {:no_stage, stage_name},
         {:ok, %{"data" => card}} <- request(:post, "/api/cards/#{ref}/move", %{stage: stage_id}) do
      {:ok, render(opts, card, format_card_line(card))}
    else
      {:no_stage, name} -> {:error, "no stage named #{inspect(name)} on this board"}
      other -> other
    end
  end

  @doc "Sets the card's status (queued|working|needs_input|in_review|done)."
  def status(ref, status, opts) do
    with {:ok, %{"data" => card}} <- request(:patch, "/api/cards/#{ref}", %{status: status}) do
      {:ok, render(opts, card, format_card_line(card))}
    end
  end

  @doc "Flags the card as needs_input with a question (recorded as an agent comment)."
  def needs_input(ref, question, opts) do
    with {:ok, %{"data" => card}} <- request(:post, "/api/cards/#{ref}/needs-input", %{question: question}) do
      {:ok, render(opts, card, format_card_line(card))}
    end
  end

  @doc "Sends the card back with a note; `to` (stage name/id) overrides the target."
  def reject(ref, note, opts, to \\ nil) do
    body = if to, do: %{note: note, to: to}, else: %{note: note}

    with {:ok, %{"data" => card}} <- request(:post, "/api/cards/#{ref}/reject", body) do
      {:ok, render(opts, card, format_card_line(card))}
    end
  end

  @doc "Claims the card for the AI agent (replaces owners with the agent)."
  def own(ref, opts) do
    with {:ok, %{"data" => card}} <- request(:patch, "/api/cards/#{ref}", %{owners: ["agent"]}) do
      {:ok, render(opts, card, format_card_line(card))}
    end
  end

  @doc "Releases the card (clears its owners so a human can pick it up)."
  def release(ref, opts) do
    with {:ok, %{"data" => card}} <- request(:patch, "/api/cards/#{ref}", %{owners: []}) do
      {:ok, render(opts, card, format_card_line(card))}
    end
  end

  @doc "Renders `human` unless `opts[:json]`, in which case pretty JSON of `data`."
  def render(opts, data, human) do
    if opts[:json], do: Jason.encode!(data, pretty: true), else: human
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> {:error, "#{name} is not set"}
      "" -> {:error, "#{name} is not set"}
      value -> {:ok, value}
    end
  end

  defp send_request(req, method, path, body) do
    result =
      case method do
        :get -> Req.get(req, url: path)
        :patch -> Req.patch(req, url: path, json: body)
        :post -> Req.post(req, url: path, json: body)
      end

    case result do
      {:ok, %{status: status, body: b}} when status in 200..299 -> {:ok, b}
      {:ok, %{status: status, body: %{"error" => %{"message" => m}}}} -> {:error, "API #{status}: #{m}"}
      {:ok, %{status: status}} -> {:error, "API error #{status}"}
      {:error, exception} -> {:error, "request failed: #{Exception.message(exception)}"}
    end
  end

  defp format_board(board) do
    header = "#{board["board"]["name"]} (#{board["board"]["key"]})"
    by_stage = Enum.group_by(board["cards"], & &1["stage_id"])

    stage_lines =
      Enum.map_join(board["stages"], "\n\n", fn stage ->
        cards = Map.get(by_stage, stage["id"], [])
        cards_text = if cards == [], do: "  (empty)", else: Enum.map_join(cards, "\n", &("  " <> format_card_line(&1)))
        "#{stage["name"]} (#{stage["owner"]})\n#{cards_text}"
      end)

    "#{header}\n\n#{stage_lines}"
  end

  defp format_card(card) do
    owners = Enum.map_join(card["owners"], ", ", & &1["name"])

    """
    #{rejection_banner(card["rejection"])}#{card["ref"]}  #{card["title"]}
    status: #{card["status"]}   active: #{card["active_owner"] || "-"}   owners: #{owners}

    #{card["description"] || "(no description)"}

    timeline:
    #{Enum.map_join(card["timeline"] || [], "\n", &format_entry/1)}
    """
  end

  # RLY-30: an open rejection reads as an instruction at the very top of the card
  # the headless AI pass sees — not a buried log line.
  defp rejection_banner(nil), do: ""

  defp rejection_banner(r) do
    date = r["rejected_at"] |> to_string() |> String.slice(0, 10)

    """
    ⚠  CHANGES REQUESTED — sent back to #{r["to_stage"]} by #{r["rejected_by"]} (#{date})
       #{r["note"]}
       Address this, then redo the stage.

    """
  end

  defp format_card_line(card) do
    owner = card["active_owner"] || "-"
    "#{card["ref"]} [#{card["status"]}/#{owner}] #{card["title"]}"
  end

  defp format_entry(%{"kind" => "comment"} = e), do: "  - #{e["author"]["name"]}: #{e["body"]}"
  defp format_entry(%{"kind" => "activity"} = e), do: "  * #{e["author"]["name"]} #{e["type"]} #{inspect(e["meta"])}"
end
