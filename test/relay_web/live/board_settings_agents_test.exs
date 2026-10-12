defmodule RelayWeb.BoardSettingsAgentsTest do
  @moduledoc "RE433 — Settings → Agents: named agents and editable harnesses."
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Agents
  alias Relay.Boards
  alias Schemas.Flow

  setup %{conn: conn} do
    user = insert(:user)
    board = Boards.get_or_create_default_board(user)
    %{conn: log_in_user(conn, user), board: board}
  end

  defp open(conn, board) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=agents")
    view
  end

  defp harness(board, name), do: Enum.find(Agents.list_harnesses(board), &(&1.name == name))
  defp agent(board, name), do: Enum.find(Agents.list_agents(board), &(&1.name == name))

  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() |> squish()
  end

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp option_values(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
  end

  defp add_agent(view, harness, model, name) do
    view |> element("#agent-add") |> render_click()
    view |> element("#agent-form-harness-#{harness.id}") |> render_click()

    view
    |> form("#agent-form", agent: %{model: model, name: name})
    |> render_submit()
  end

  defp edit_harness_models(view, harness, models) do
    view |> element("#harness-card-#{harness.id}-edit") |> render_click()

    view
    |> form("#harness-form", harness: %{models: models})
    |> render_submit()
  end

  test "1. the Agents pane lists the seeded agents and harnesses", %{conn: conn, board: board} do
    view = open(conn, board)

    assert text(view, "#settings-title") == "Agents"
    assert has_element?(view, "#agents-pane h1", "Agents")

    rows = view |> render() |> LazyHTML.from_document() |> LazyHTML.query("#agents-table [id^='agent-row-'][data-agent]")
    assert Enum.count(rows) == 3

    opus = agent(board, "Claude Opus")

    for name <- ["Claude Opus", "Claude Sonnet", "Claude Haiku"] do
      row = agent(board, name)
      assert has_element?(view, "#agent-row-#{row.id}", name)
      assert has_element?(view, "#agent-row-#{row.id}", "Claude Code")

      if row.id == opus.id do
        assert text(view, "#agent-row-#{row.id}-default") == "DEFAULT"
      else
        refute has_element?(view, "#agent-row-#{row.id}-default")
      end
    end

    assert has_element?(view, "#agent-row-#{opus.id} [data-used-by]", "all others")

    for name <- ["Claude Code", "Codex", "Gemini CLI"] do
      h = harness(board, name)
      assert has_element?(view, "#harnesses #harness-card-#{h.id}", name)

      assert view |> element("#harness-card-#{h.id}-command") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() ==
               h.command

      for model <- h.models do
        assert has_element?(view, "#harness-card-#{h.id} [data-model-chip]", model)
      end
    end

    refute render(view) =~ ~r/custom/i
  end

  test "3. Add agent offers only the picked harness's models in a select", %{conn: conn, board: board} do
    view = open(conn, board)
    codex = harness(board, "Codex")

    view |> element("#agent-add") |> render_click()
    view |> element("#agent-form-harness-#{codex.id}") |> render_click()

    assert has_element?(view, "#agent-form-harness-#{codex.id}.btn-primary")
    assert option_values(view, "#agent-form-model option") == codex.models
    refute has_element?(view, "input[name='agent[model]']")
  end

  describe "a red agent" do
    setup %{conn: conn, board: board} do
      view = open(conn, board)
      gemini = harness(board, "Gemini CLI")
      add_agent(view, gemini, "gemini-2.5-pro", "Gemini Pro")
      %{view: view, gemini: gemini, pro: agent(board, "Gemini Pro")}
    end

    test "4. adding an agent and dropping its model from the harness turns its row red",
         %{view: view, gemini: gemini, pro: pro} do
      assert has_element?(view, "#agent-row-#{pro.id} [data-used-by]", "—")
      assert has_element?(view, "#agent-row-#{pro.id}-make-default", "Make default")
      refute has_element?(view, "#agent-row-#{pro.id}[data-red]")

      edit_harness_models(view, gemini, "gemini-2.5-flash")

      refute has_element?(view, "#harness-form")
      assert has_element?(view, "#agent-row-#{pro.id}[data-red='true']")
      assert text(view, "#agent-row-#{pro.id}-removed") == "MODEL REMOVED"
      assert has_element?(view, "#agent-row-#{pro.id} .line-through", "gemini-2.5-pro")
      assert has_element?(view, "#agent-row-#{pro.id}", "not in Gemini CLI's models")

      red = text(view, "#harness-card-#{gemini.id}-red")
      assert red == "1 agent uses a model that isn't on this list: Gemini Pro (gemini-2.5-pro)."
    end

    test "5. editing a red agent forces a model choice before Save", %{view: view, gemini: gemini, pro: pro} do
      edit_harness_models(view, gemini, "gemini-2.5-flash")
      view |> element("#agent-row-#{pro.id}-edit") |> render_click()

      assert has_element?(view, "#agent-form", "Edit agent · Gemini Pro")
      assert [""] == option_values(view, "#agent-form-model option:first-child")
      assert has_element?(view, "#agent-form-model option:first-child", "Choose a model…")
      refute has_element?(view, "#agent-form-model option[value='gemini-2.5-pro']")
      assert has_element?(view, "#agent-form-save[disabled]")

      assert has_element?(
               view,
               "#agent-form",
               "Only Gemini CLI's current models. gemini-2.5-pro isn't offered any more, so this row stays red until you pick one."
             )

      view |> form("#agent-form", agent: %{model: "gemini-2.5-flash"}) |> render_change()
      assert has_element?(view, "#agent-form-save")
      refute has_element?(view, "#agent-form-save[disabled]")

      view |> form("#agent-form") |> render_submit()
      refute has_element?(view, "#agent-form")
      refute has_element?(view, "#agent-row-#{pro.id}[data-red]")
    end

    test "7. a harness in use refuses removal until its agents are gone",
         %{view: view, gemini: gemini, pro: pro} do
      view |> element("#harness-card-#{gemini.id}-edit") |> render_click()
      view |> element("#harness-delete") |> render_click()

      assert text(view, "#harness-error") ==
               "Gemini CLI is used by Gemini Pro. Delete or move those agents first."

      assert has_element?(view, "#harness-card-#{gemini.id}")

      view |> element("#agent-row-#{pro.id}-edit") |> render_click()
      view |> element("#agent-delete") |> render_click()
      view |> element("#harness-delete") |> render_click()

      refute has_element?(view, "#agent-row-#{pro.id}")
      refute has_element?(view, "#harness-card-#{gemini.id}")
      refute render(view) =~ "Gemini Pro"
    end
  end

  test "6. Make default moves the DEFAULT badge", %{conn: conn, board: board} do
    view = open(conn, board)
    opus = agent(board, "Claude Opus")
    sonnet = agent(board, "Claude Sonnet")

    refute has_element?(view, "#agent-row-#{opus.id}-make-default")

    view |> element("#agent-row-#{sonnet.id}-make-default") |> render_click()

    assert text(view, "#agent-row-#{sonnet.id}-default") == "DEFAULT"
    refute has_element?(view, "#agent-row-#{opus.id}-default")
    assert has_element?(view, "#agent-row-#{opus.id}-make-default", "Make default")
    assert Agents.default_agent(board).name == "Claude Sonnet"
  end

  describe "8. deleting an agent" do
    test "refuses the board default", %{conn: conn, board: board} do
      view = open(conn, board)
      opus = agent(board, "Claude Opus")

      view |> element("#agent-row-#{opus.id}-edit") |> render_click()
      view |> element("#agent-delete") |> render_click()

      assert text(view, "#agent-error") ==
               "Claude Opus is the board default. Make another agent the default first."

      assert has_element?(view, "#agent-row-#{opus.id}")
    end

    test "refuses an agent flow nodes name, listing them by flow", %{conn: conn, board: board} do
      view = open(conn, board)
      sonnet = agent(board, "Claude Sonnet")

      view |> element("#agent-row-#{sonnet.id}-edit") |> render_click()
      view |> element("#agent-delete") |> render_click()

      assert text(view, "#agent-error") ==
               "Claude Sonnet is used by code: spec_review, sync_fix, acceptance, resync_fix, post. " <>
                 "Point those nodes at another LLM first."

      assert has_element?(view, "#agent-row-#{sonnet.id}")
    end

    test "joins several flows with '; '", %{conn: conn, board: board} do
      haiku = agent(board, "Claude Haiku")
      [first, two | _] = Relay.Repo.all(from f in Flow, where: f.board_id == ^board.id, order_by: f.key)
      refute Map.has_key?(Agents.node_usage(board), "Claude Haiku")

      for flow <- [first, two] do
        [node | rest] = flow.nodes

        flow
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_embed(:nodes, [%{node | llm: "Claude Haiku"} | rest])
        |> Relay.Repo.update!()
      end

      view = open(conn, board)
      view |> element("#agent-row-#{haiku.id}-edit") |> render_click()
      view |> element("#agent-delete") |> render_click()

      [n1 | _] = first.nodes
      [n2 | _] = two.nodes

      assert text(view, "#agent-error") ==
               "Claude Haiku is used by #{first.key}: #{n1.key}; #{two.key}: #{n2.key}. " <>
                 "Point those nodes at another LLM first."
    end
  end

  test "9. adding a harness shows its card and offers it to new agents", %{conn: conn, board: board} do
    view = open(conn, board)

    view |> element("#harness-add") |> render_click()

    html =
      view
      |> form("#harness-form", harness: %{name: "pi", command: "pi --model {model}", models: "qwen3-coder"})
      |> render_submit()

    assert html =~ "must contain {prompt}"
    assert has_element?(view, "#harness-form", "must contain {prompt}")

    view
    |> form("#harness-form",
      harness: %{
        name: "pi",
        command: "pi -p {prompt} --model {model} --cwd {worktree}",
        models: "qwen3-coder, deepseek-v3"
      }
    )
    |> render_submit()

    refute has_element?(view, "#harness-form")
    pi = harness(board, "pi")
    assert has_element?(view, "#harness-card-#{pi.id} [data-model-chip]", "qwen3-coder")
    assert has_element?(view, "#harness-card-#{pi.id} [data-model-chip]", "deepseek-v3")
    assert length(Agents.list_harnesses(board)) == 4

    view |> element("#agent-add") |> render_click()
    assert has_element?(view, "#agent-form-harness-#{pi.id}", "pi")
  end

  describe "harness USAGE (RE436)" do
    @allowed ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.42,"resetsAt":1791651000},"seven_day":{"utilization":0.18,"resetsAt":1792000000}}}})

    defp usage_chips(view, harness) do
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#harness-card-#{harness.id}-usage [data-usage-window-chip]")
      |> Enum.map(&(&1 |> LazyHTML.text() |> squish()))
    end

    defp edit(view, harness), do: view |> element("#harness-card-#{harness.id}-edit") |> render_click()

    defp try_line(view, line) do
      view |> form("#harness-form") |> render_change(%{"usage_test_line" => line})
      view |> element("#harness-form-usage-try") |> render_click()
      text(view, "#harness-form-usage-test-result")
    end

    test "1. each collapsed harness card summarizes its USAGE", %{conn: conn, board: board} do
      view = open(conn, board)
      claude = harness(board, "Claude Code")
      codex = harness(board, "Codex")
      gemini = harness(board, "Gemini CLI")

      assert text(view, "#harness-card-#{claude.id}-usage") =~
               ~s(From its output · reading when .type == "rate_limit_event")

      assert usage_chips(view, claude) == [
               "5h · .rate_limit_info.unifiedWindows.five_hour.utilization · pause at 90%",
               "7d · .rate_limit_info.unifiedWindows.seven_day.utilization · pause at 90%"
             ]

      codex_text = text(view, "#harness-card-#{codex.id}-usage")
      assert codex_text =~ "From a command ·"
      assert codex_text =~ "every 5 min"
      assert [five_hour, week] = usage_chips(view, codex)
      assert String.starts_with?(five_hour, "5h ·")
      assert String.starts_with?(week, "wk ·")
      assert String.ends_with?(five_hour, "pause at 90%")
      assert String.ends_with?(week, "pause at 90%")

      assert text(view, "#harness-card-#{gemini.id}-usage") ==
               "Not reported — runners show “—” and never pause Gemini CLI for usage."
    end

    test "2. TEST reads an allowed line's windows and says it would not pause", %{conn: conn, board: board} do
      view = open(conn, board)
      edit(view, harness(board, "Claude Code"))

      result = try_line(view, @allowed)

      assert result =~ "✓ reading"
      assert result =~ "5h 42% · resets "
      assert result =~ "7d 18% · resets "
      assert result =~ "not paused"
    end

    test "3. TEST says why a line is not a reading", %{conn: conn, board: board} do
      view = open(conn, board)
      edit(view, harness(board, "Claude Code"))

      result = try_line(view, ~s({"type":"assistant"}))
      assert result =~ "✗"
      assert result =~ "not a reading"

      assert try_line(view, "not json") =~ "✗ not valid JSON"
    end

    test "3b. Try it never submits the harness form", %{conn: conn, board: board} do
      view = open(conn, board)
      edit(view, harness(board, "Claude Code"))

      assert view |> element("#harness-form-usage-try") |> render() =~ ~s(type="button")
      try_line(view, @allowed)
      assert has_element?(view, "#harness-form")
    end

    test "4. a Codex window's pause at is edited and a window added", %{conn: conn, board: board} do
      view = open(conn, board)
      codex = harness(board, "Codex")
      edit(view, codex)

      view
      |> form("#harness-form", harness: %{usage: %{windows_sort: ["0", "1", "new"]}})
      |> render_change()

      assert has_element?(view, "#harness-form-usage-window-2")

      view
      |> form("#harness-form",
        harness: %{
          usage: %{
            windows: %{
              "0" => %{pause_at: "50"},
              "2" => %{
                label: "day",
                used_path: ".payload.d.used_percent",
                resets_path: ".payload.d.resets_at",
                pause_at: "80"
              }
            }
          }
        }
      )
      |> render_submit()

      refute has_element?(view, "#harness-form")
      chips = usage_chips(view, codex)
      assert "5h · .payload.rate_limits.primary.used_percent · pause at 50%" in chips
      assert "day · .payload.d.used_percent · pause at 80%" in chips
      saved = harness(board, "Codex").usage
      assert length(saved.windows) == 3
      assert saved.pause_now == nil
      assert saved.recheck.model == "gpt-5.6-luna"
    end

    test "5. the source switch shows only what that source needs", %{conn: conn, board: board} do
      view = open(conn, board)
      edit(view, harness(board, "Claude Code"))

      assert has_element?(view, "#harness-form-usage-match")
      refute has_element?(view, "#harness-form-usage-command")

      view |> form("#harness-form", harness: %{usage: %{source: "none"}}) |> render_change()
      refute has_element?(view, "#harness-form-usage-match")
      refute has_element?(view, "#harness-form-usage-try")

      view |> form("#harness-form", harness: %{usage: %{source: "command"}}) |> render_change()
      assert has_element?(view, "#harness-form-usage-command")
      assert has_element?(view, "#harness-form-usage-interval")
    end

    test "6. an invalid match or re-check model keeps the form open with the error", %{conn: conn, board: board} do
      view = open(conn, board)
      edit(view, harness(board, "Claude Code"))

      view |> form("#harness-form", harness: %{usage: %{match: ".a = 1"}}) |> render_submit()
      assert has_element?(view, "#harness-form")
      assert has_element?(view, "#harness-form", ~s(is not a condition like .type == "x"))

      view
      |> form("#harness-form", harness: %{usage: %{match: ~s(.type == "rate_limit_event")}})
      |> render_submit(%{"harness" => %{"usage" => %{"recheck" => %{"model" => "gpt"}}}})

      assert has_element?(view, "#harness-form")
      assert has_element?(view, "#harness-form", "is not one of this harness's models")
    end

    test "editing another harness starts with an empty TEST box", %{conn: conn, board: board} do
      view = open(conn, board)
      edit(view, harness(board, "Claude Code"))
      try_line(view, @allowed)

      edit(view, harness(board, "Codex"))

      refute has_element?(view, "#harness-form-usage-test-result")
    end

    test "closing the panel resets the TEST box", %{conn: conn, board: board} do
      view = open(conn, board)
      claude = harness(board, "Claude Code")
      edit(view, claude)
      try_line(view, @allowed)

      view |> element("#harness-form button", "Cancel") |> render_click()
      edit(view, claude)

      refute has_element?(view, "#harness-form-usage-test-result", "reading")
      assert view |> element("#harness-form-usage-test-line") |> render() =~ ~r{<textarea[^>]*>\s*</textarea>}
    end
  end

  test "10. an agent name already on the board is refused", %{conn: conn, board: board} do
    view = open(conn, board)

    add_agent(view, harness(board, "Claude Code"), "opus", "Claude Opus")

    assert has_element?(view, "#agent-form", "is already used on this board")
    assert length(Agents.list_agents(board)) == 3
  end

  test "11. an archived board refuses agent and harness mutations", %{conn: conn, board: board} do
    {:ok, _archived} = Boards.archive_board(board)
    view = open(conn, board)

    assert render_click(view, "agent_new", %{}) =~ "This board is archived (read-only)."

    assert render_click(view, "harness_save", %{"harness" => %{"name" => "x", "command" => "x {prompt}", "models" => "a"}}) =~
             "This board is archived (read-only)."

    assert length(Agents.list_harnesses(board)) == 3
  end
end
