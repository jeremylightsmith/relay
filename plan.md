# Plan — MMF 10: Relay CLI + agent integration docs

**Spec:** `docs/superpowers/specs/2026-07-07-relay-cli-design.md`

## Goal

Give Claude Code a terminal CLI to work a Relay board: a `mix relay <cmd>` dispatcher over the
MMF 09 REST API (config from `RELAY_URL` + `RELAY_API_KEY`), human output by default with
`--json` on every command, clear errors + non-zero exit. Plus **`docs/agent-integration.md`** —
the CLI reference and an example Claude Code agent/workflow/skill (docs-only; we do NOT modify
the repo's real `.claude/` setup in this MMF). The live "wire this session to Relay" dogfood is a
later, deliberate step done with the maintainer.

## Architecture

- **`Relay.CLI`** (its own boundary, `lib/relay/cli.ex`) holds the HTTP client + one function
  per command. It talks to Relay **only over HTTP via `Req`** (it is an external API client, not
  a context call). Command functions return `{:ok, output_string} | {:error, message}` so they
  are unit-testable without Mix. Requests merge `Application.get_env(:relay, :cli_req_options,
  [])` so tests can inject a `Req.Test` plug.
- **`Mix.Tasks.Relay`** (`lib/mix/tasks/relay.ex`) is one thin dispatcher — `mix relay board`,
  `mix relay pull`, `mix relay comment RLY-12 "text"`, etc. It parses argv + `--json`, calls the
  matching `Relay.CLI` function, prints the result, and `exit({:shutdown, 1})` on error. It is
  classified into the `Relay.CLI` boundary via `use Boundary, classify_to: Relay.CLI` (the
  documented way to place mix tasks in a boundary).

## Tech

`Req` (already a dep), `Jason`, `Mix.Task`, `Boundary`. No new deps.

## Global Constraints (verbatim intent from AGENTS.md + spec)

- `mix precommit` MUST pass (compile warnings-as-errors, `mix format` w/ Styler, `mix credo
  --strict`, `mix sobelow`, `mix deps.audit`, full suite).
- **Boundaries enforced by the compiler.** `Relay.CLI` is its own boundary (`deps: []`; it only
  uses external apps `Req`/`Jason`). The mix task MUST use `use Boundary, classify_to: Relay.CLI`
  — an unclassified module would fail the boundary compiler.
- Use `Req` for HTTP — never `:httpoison`/`:tesla`/`:httpc`.
- Never `String.to_atom/1` on user input.
- Elixir lists: no index access via `list[i]`; use `Enum`/pattern matching.
- The CLI is an API client — it must NOT call `Relay.*` contexts or `Relay.Repo` directly.
- Predicate functions end in `?`, never `is_` prefix (that's for guards).

## MMF 09 API shapes the CLI consumes (Consumes)

- `GET /api/board` → `%{"board" => %{"name","key",...}, "stages" => [%{"id","name","category","owner","position"}], "cards" => [card]}`
- card = `%{"id","ref","title","tag","status","progress","stage_id","owners" => [%{"type","name","id"?}], "active_owner" => "ai"|"human"|nil}`
- `GET /api/cards` → `%{"data" => [card]}`
- `GET /api/cards/:ref` → `%{"data" => card ++ %{"description", "timeline" => [entry]}}`; entry = `%{"kind"=>"comment","body","author"=>%{"type","name"},"inserted_at"}` or `%{"kind"=>"activity","type","meta","author","inserted_at"}`
- `PATCH /api/cards/:ref` (`title`/`description`/`tag`/`status`/`progress`/`owners`) → `%{"data" => card}`
- `POST /api/cards/:ref/move` (`stage` id, optional `position`) → `%{"data" => card}`
- `POST /api/cards/:ref/comments` (`body`) → 201 `%{"data" => entry}`
- `POST /api/cards/:ref/needs-input` (`question`) → `%{"data" => card}`
- errors → non-2xx with `%{"error" => %{"code","message"}}`

---

## Task 1: `Relay.CLI` client core + read commands (`board`, `card`, `pull`) + dispatcher

**Files**
- create `lib/relay/cli.ex` — `Relay.CLI` boundary: `request/3`, `board/1`, `card/2`, `pull/1`, formatting helpers
- create `lib/mix/tasks/relay.ex` — `Mix.Tasks.Relay` dispatcher (read subcommands; write ones added in Task 2)
- modify `config/test.exs` — inject the `Req.Test` plug for the CLI
- create `test/relay/cli_test.exs`

**Interfaces**
- *Produces:*
  - `Relay.CLI.request(method :: :get|:patch|:post, path :: binary, body :: map | nil) :: {:ok, map} | {:error, binary}`
  - `Relay.CLI.board(opts :: keyword) :: {:ok, binary} | {:error, binary}` (`opts[:json]` toggles raw JSON)
  - `Relay.CLI.card(ref :: binary, opts) :: {:ok, binary} | {:error, binary}`
  - `Relay.CLI.pull(opts) :: {:ok, binary} | {:error, binary}`
  - `Relay.CLI.render(opts, data :: term, human :: binary) :: binary`

### Steps

- [x] **Test config seam.** In `config/test.exs`, add:

```elixir
# Route Relay.CLI's HTTP requests to a Req.Test stub in tests.
config :relay, cli_req_options: [plug: {Req.Test, Relay.CLI}]
```

- [x] **Failing tests.** Create `test/relay/cli_test.exs`:

```elixir
defmodule Relay.CLITest do
  use ExUnit.Case, async: true

  alias Relay.CLI

  setup do
    System.put_env("RELAY_URL", "http://relay.test")
    System.put_env("RELAY_API_KEY", "relay_abc_def")
    on_exit(fn -> System.delete_env("RELAY_URL"); System.delete_env("RELAY_API_KEY") end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(Relay.CLI, fun)

  test "board/1 renders stages and cards, and --json returns raw JSON" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "board" => %{"name" => "My board", "key" => "RLY"},
        "stages" => [%{"id" => 1, "name" => "Spec", "owner" => "human", "category" => "unstarted", "position" => 1}],
        "cards" => [%{"ref" => "RLY-1", "title" => "Do it", "status" => "working", "stage_id" => 1, "owners" => [], "active_owner" => nil}]
      })
    end)

    assert {:ok, text} = CLI.board([])
    assert text =~ "My board"
    assert text =~ "Spec"
    assert text =~ "RLY-1"
    assert text =~ "Do it"

    assert {:ok, json} = CLI.board(json: true)
    assert Jason.decode!(json)["board"]["key"] == "RLY"
  end

  test "card/2 renders the card + timeline" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "ref" => "RLY-1", "title" => "Do it", "status" => "in_review", "description" => "the details",
          "owners" => [%{"type" => "agent", "name" => "Relay AI"}], "active_owner" => "ai",
          "timeline" => [%{"kind" => "comment", "body" => "hi", "author" => %{"type" => "agent", "name" => "Relay AI"}, "inserted_at" => "2026-07-07T00:00:00Z"}]
        }
      })
    end)

    assert {:ok, text} = CLI.card("RLY-1", [])
    assert text =~ "RLY-1"
    assert text =~ "the details"
    assert text =~ "Relay AI"
    assert text =~ "hi"
  end

  test "pull/1 returns the first AI-owned card, else an unclaimed card in an AI stage" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "board" => %{"name" => "B", "key" => "RLY"},
        "stages" => [%{"id" => 1, "name" => "Spec", "owner" => "human", "category" => "unstarted", "position" => 1},
                     %{"id" => 2, "name" => "Code", "owner" => "ai", "category" => "in_progress", "position" => 2}],
        "cards" => [
          %{"ref" => "RLY-1", "title" => "Human card", "status" => "queued", "stage_id" => 1, "owners" => [], "active_owner" => nil},
          %{"ref" => "RLY-2", "title" => "Unclaimed AI-stage", "status" => "queued", "stage_id" => 2, "owners" => [], "active_owner" => nil}
        ]
      })
    end)

    assert {:ok, text} = CLI.pull([])
    assert text =~ "RLY-2"
    refute text =~ "RLY-1"
  end

  test "request/3 surfaces API errors and missing config" do
    stub(fn conn -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => %{"code" => "not_found", "message" => "No card RLY-9"}}) end)
    assert {:error, msg} = CLI.card("RLY-9", [])
    assert msg =~ "No card RLY-9"

    System.delete_env("RELAY_API_KEY")
    assert {:error, msg2} = CLI.board([])
    assert msg2 =~ "RELAY_API_KEY"
  end
end
```

- [x] **Run — expect fail** (`Relay.CLI` undefined).

- [x] **Implement `Relay.CLI`.** Create `lib/relay/cli.ex`:

```elixir
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
    owners = card["owners"] |> Enum.map_join(", ", & &1["name"])
    """
    #{card["ref"]}  #{card["title"]}
    status: #{card["status"]}   active: #{card["active_owner"] || "-"}   owners: #{owners}

    #{card["description"] || "(no description)"}

    timeline:
    #{Enum.map_join(card["timeline"] || [], "\n", &format_entry/1)}
    """
  end

  defp format_card_line(card) do
    owner = card["active_owner"] || "-"
    "#{card["ref"]} [#{card["status"]}/#{owner}] #{card["title"]}"
  end

  defp format_entry(%{"kind" => "comment"} = e), do: "  - #{e["author"]["name"]}: #{e["body"]}"
  defp format_entry(%{"kind" => "activity"} = e), do: "  * #{e["author"]["name"]} #{e["type"]} #{inspect(e["meta"])}"
end
```

- [x] **Implement the dispatcher.** Create `lib/mix/tasks/relay.ex`:

```elixir
defmodule Mix.Tasks.Relay do
  @shortdoc "Relay CLI — drive a Relay board from the terminal"
  @moduledoc """
  Work a Relay board over the REST API. Configure `RELAY_URL` and
  `RELAY_API_KEY`, then:

      mix relay board
      mix relay card RLY-12
      mix relay pull

  Add `--json` to any command for machine-readable output.
  """
  use Boundary, classify_to: Relay.CLI
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:req)
    {json?, args} = pop_json(argv)

    case dispatch(args, json: json?) do
      {:ok, output} ->
        IO.puts(output)

      {:error, message} ->
        IO.puts(:stderr, message)
        exit({:shutdown, 1})
    end
  end

  defp dispatch(["board"], opts), do: Relay.CLI.board(opts)
  defp dispatch(["card", ref], opts), do: Relay.CLI.card(ref, opts)
  defp dispatch(["pull"], opts), do: Relay.CLI.pull(opts)
  defp dispatch(_argv, _opts), do: {:error, usage()}

  defp pop_json(argv), do: {"--json" in argv, argv -- ["--json"]}

  defp usage do
    "usage: mix relay <board | card REF | pull> [--json]"
  end
end
```

- [x] **Run — expect pass.**

- [x] **Full check + commit.** `mix precommit`. Commit: `feat(cli): mix relay client core + board/card/pull`.

**Deliverable:** `mix relay board|card REF|pull` work against a live board (env-configured), with `--json` and clear errors/non-zero exit; the client core is unit-tested via a `Req.Test` stub.

---

## Task 2: write commands — `comment`, `move`, `status`, `needs-input`, `own`, `release`

**Files**
- modify `lib/relay/cli.ex` — add `comment/3`, `move/3`, `status/3`, `needs_input/3`, `own/2`, `release/2`
- modify `lib/mix/tasks/relay.ex` — dispatch the write subcommands
- modify `test/relay/cli_test.exs` — cover the write commands

**Interfaces**
- *Consumes:* `Relay.CLI.request/3`, `render/3`, `format_card_line/1`.
- *Produces:*
  - `Relay.CLI.comment(ref, body, opts) :: {:ok, binary} | {:error, binary}`
  - `Relay.CLI.move(ref, stage_name, opts) :: {:ok, binary} | {:error, binary}` (resolves stage name → id via `/api/board`)
  - `Relay.CLI.status(ref, status, opts) :: {:ok, binary} | {:error, binary}`
  - `Relay.CLI.needs_input(ref, question, opts) :: {:ok, binary} | {:error, binary}`
  - `Relay.CLI.own(ref, opts) :: {:ok, binary} | {:error, binary}` (PATCH owners `["agent"]`)
  - `Relay.CLI.release(ref, opts) :: {:ok, binary} | {:error, binary}` (PATCH owners `[]`)

### Steps

- [x] **Failing tests.** Append to `test/relay/cli_test.exs` (inside the module):

```elixir
  test "comment posts and confirms" do
    stub(fn conn ->
      assert conn.method == "POST"
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"data" => %{"kind" => "comment", "body" => "on it", "author" => %{"name" => "Relay AI"}}})
    end)

    assert {:ok, text} = CLI.comment("RLY-1", "on it", [])
    assert text =~ "RLY-1"
  end

  test "move resolves a stage name to its id then posts" do
    stub(fn conn ->
      case conn.request_path do
        "/api/board" ->
          Req.Test.json(conn, %{"board" => %{"name" => "B", "key" => "RLY"},
            "stages" => [%{"id" => 7, "name" => "Code", "owner" => "ai", "category" => "in_progress", "position" => 2}], "cards" => []})

        "/api/cards/RLY-1/move" ->
          assert Jason.decode!(conn |> Plug.Conn.read_body() |> elem(1))["stage"] == 7
          Req.Test.json(conn, %{"data" => %{"ref" => "RLY-1", "title" => "X", "status" => "queued", "stage_id" => 7, "active_owner" => "ai", "owners" => []}})
      end
    end)

    assert {:ok, text} = CLI.move("RLY-1", "Code", [])
    assert text =~ "RLY-1"
  end

  test "move errors when the stage name is unknown" do
    stub(fn conn -> Req.Test.json(conn, %{"board" => %{"name" => "B", "key" => "RLY"}, "stages" => [], "cards" => []}) end)
    assert {:error, msg} = CLI.move("RLY-1", "Nope", [])
    assert msg =~ "Nope"
  end

  test "status, needs_input, own, release hit the right endpoints" do
    stub(fn conn ->
      Req.Test.json(conn, %{"data" => %{"ref" => "RLY-1", "title" => "X", "status" => "working", "active_owner" => "ai", "owners" => [%{"type" => "agent", "name" => "Relay AI"}]}})
    end)

    assert {:ok, _} = CLI.status("RLY-1", "working", [])
    assert {:ok, _} = CLI.needs_input("RLY-1", "Which region?", [])
    assert {:ok, _} = CLI.own("RLY-1", [])
    assert {:ok, _} = CLI.release("RLY-1", [])
  end
```

- [x] **Run — expect fail.**

- [x] **Implement the write commands.** Add to `lib/relay/cli.ex`:

```elixir
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
```

- [x] **Dispatch the write commands.** In `lib/mix/tasks/relay.ex`, add clauses **above** the catch-all `dispatch(_argv, _opts)`:

```elixir
  defp dispatch(["comment", ref, body], opts), do: Relay.CLI.comment(ref, body, opts)
  defp dispatch(["move", ref, stage], opts), do: Relay.CLI.move(ref, stage, opts)
  defp dispatch(["status", ref, status], opts), do: Relay.CLI.status(ref, status, opts)
  defp dispatch(["needs-input", ref, question], opts), do: Relay.CLI.needs_input(ref, question, opts)
  defp dispatch(["own", ref], opts), do: Relay.CLI.own(ref, opts)
  defp dispatch(["release", ref], opts), do: Relay.CLI.release(ref, opts)
```

And extend `usage/0`:

```elixir
  defp usage do
    """
    usage: mix relay <command> [--json]
      board                      show the board
      card REF                   show a card + timeline
      pull                       next AI card to work
      comment REF "text"         post a comment
      move REF STAGE             move to a stage (by name)
      status REF STATUS          set status
      needs-input REF "question" flag needs_input with a question
      own REF                    claim the card for the AI
      release REF                clear owners
    """
  end
```

- [x] **Run — expect pass.**

- [x] **Full check + commit.** `mix precommit`. Commit: `feat(cli): comment/move/status/needs-input/own/release commands`.

**Deliverable:** the full agent verb set works end-to-end over the API; `move` resolves a stage by name; every command supports `--json`; unit tests cover each via `Req.Test`.

---

## Task 3: `docs/agent-integration.md` + AGENTS.md link

**Files**
- create `docs/agent-integration.md`
- modify `AGENTS.md` — add a short "Working Relay from Claude Code" pointer to the doc
- create `test/relay_web/agent_integration_docs_test.exs` — a lightweight doc-contract test

**Interfaces**
- *Produces:* the integration guide (setup, CLI reference, example agent/workflow/skill, dogfood walkthrough).

### Steps

- [ ] **Failing doc-contract test.** Create `test/relay_web/agent_integration_docs_test.exs` (guards that the doc exists and documents every shipped command, so the docs can't silently drift from the CLI):

```elixir
defmodule Relay.AgentIntegrationDocsTest do
  use ExUnit.Case, async: true

  @doc_path Path.join([File.cwd!(), "docs", "agent-integration.md"])

  test "the integration doc documents every mix relay subcommand" do
    doc = File.read!(@doc_path)

    for cmd <- ~w(board card pull comment move status needs-input own release) do
      assert doc =~ "mix relay #{cmd}", "agent-integration.md is missing `mix relay #{cmd}`"
    end

    assert doc =~ "RELAY_URL"
    assert doc =~ "RELAY_API_KEY"
    assert doc =~ "--json"
  end

  test "AGENTS.md links to the integration doc" do
    assert File.read!(Path.join(File.cwd!(), "AGENTS.md")) =~ "docs/agent-integration.md"
  end
end
```

- [ ] **Run — expect fail** (doc/link missing).

- [ ] **Write the doc.** Create `docs/agent-integration.md`:

```markdown
# Working Relay from Claude Code

Relay is programmable over a small REST API (MMF 09) and a `mix relay` CLI (MMF 10). This guide
shows how a Claude Code session pulls a card, works it, and hands it back — the "passing the
baton" loop, driven from the terminal.

> **Scope:** this documents the CLI and gives *example* Claude Code constructs. Wiring your own
> `.claude/` setup is a copy-and-adapt step — this repo does not ship those as live config.

## Setup

1. Mint a board API key: open `/board/settings` in Relay → **Generate key** → copy the
   `relay_…` secret (shown once).
2. Export the two env vars Claude Code's shell will use:

   ```bash
   export RELAY_URL="https://<your-relay-host>"
   export RELAY_API_KEY="relay_xxxxxxxxxxxx_…"
   ```

## CLI reference

Every command prints human-readable text by default; add `--json` for machine output. Non-zero
exit on any error (bad env, auth, unknown ref, HTTP error).

| Command | What it does |
|---|---|
| `mix relay board` | The board: stages with their cards |
| `mix relay card RLY-12` | One card with description + timeline |
| `mix relay pull` | The next card to work: AI-owned first, else an unclaimed card in an AI stage |
| `mix relay comment RLY-12 "on it"` | Post a comment (as Relay AI) |
| `mix relay move RLY-12 Code` | Move the card to a stage (by name) |
| `mix relay status RLY-12 working` | Set status (`queued`/`working`/`needs_input`/`in_review`/`done`) |
| `mix relay needs-input RLY-12 "Which region?"` | Flag needs_input + record the question |
| `mix relay own RLY-12` | Claim the card for the AI |
| `mix relay release RLY-12` | Clear owners (hand back) |

## The baton loop

```bash
ref=$(mix relay pull --json | jq -r '.ref')   # find the next AI card
mix relay own "$ref"                            # take the baton
mix relay status "$ref" working                 # ...work it...
mix relay comment "$ref" "Implemented X, tests green"
mix relay move "$ref" Review                     # hand to a human stage
mix relay release "$ref"
```

## Example Claude Code setup (copy & adapt)

A **skill** that documents the loop for a session — `.claude/skills/work-relay-card/SKILL.md`:

```markdown
---
description: Pull a Relay card, do the work, hand it back via the mix relay CLI.
---

1. `mix relay pull` to get your card (its ref + description).
2. `mix relay own <ref>` and `mix relay status <ref> working`.
3. Do the work in the repo (TDD).
4. `mix relay comment <ref> "<what you did>"`; if blocked, `mix relay needs-input <ref> "<question>"`.
5. `mix relay move <ref> Review` and `mix relay release <ref>` when done.
```

An **agent** that works a single card — `.claude/agents/relay-worker.md`:

```markdown
---
name: relay-worker
description: Works one Relay card end-to-end from pull to hand-back.
tools: [Bash, Read, Edit, Write]
---

You work exactly one Relay card. Use the `work-relay-card` skill's loop. Never touch a card that
isn't the one you pulled. Report the final ref + status as your result.
```

A **workflow** (sketch) that pulls and fans out one worker per available card:

```js
// .claude/workflows/work-relay-board.js — sketch
const refs = JSON.parse(await sh("mix relay pull --json")) // extend to list multiple
await parallel(refs.map(r => () => agent(`Work Relay card ${r.ref}`, { agentType: "relay-worker" })))
```

## Dogfood

To validate: point the env vars at a real board, run `mix relay pull`, work the card, and hand
it back — then adapt the examples above into your own `.claude/` setup.
```

- [ ] **Link from AGENTS.md.** Add near the "What Relay is" / client-strategy section a short pointer:

```markdown
**Working Relay from Claude Code:** the `mix relay` CLI + REST API let a Claude session pull a
card, work it, and hand it back. See [`docs/agent-integration.md`](docs/agent-integration.md).
```

- [ ] **Run — expect pass.**

- [ ] **Full check + commit.** `mix precommit`. Commit: `docs: agent-integration guide + AGENTS.md pointer`.

**Deliverable:** `docs/agent-integration.md` documents the whole CLI + an example agent/workflow/skill and the dogfood walkthrough; AGENTS.md points to it; a doc-contract test keeps the reference in sync with the shipped commands.

---

## Spec coverage

| Spec requirement / acceptance criterion | Task |
|---|---|
| `mix relay board` prints stages + cards | 1 |
| `relay pull` returns the next agent card (AI-owned first, then unclaimed in AI stage) | 1 |
| `card`, and the write verbs `comment`/`move`/`status`/`needs-input`, worked end-to-end | 1, 2 |
| claim/release ownership (own/release) per the owners model | 2 |
| every command has `--json`; errors clear + non-zero exit | 1, 2 |
| `mix relay` CLI wraps the MMF 09 API over `Req`, env-configured | 1 |
| `docs/agent-integration.md` = CLI reference + example agent/workflow/skill | 3 |
| AGENTS.md documents how Claude Code works a card | 3 |
| (dogfood — connect this session live) | done manually after merge, per scope decision |
