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

      assert view |> element("#harness-card-#{h.id} code") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() ==
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
