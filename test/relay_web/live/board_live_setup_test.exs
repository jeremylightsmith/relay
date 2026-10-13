defmodule RelayWeb.BoardLiveSetupTest do
  @moduledoc """
  RE443 task 4: the setup wizard on the board — the docked-left panel (`#setup-panel`), the
  top-bar chip (`#setup-chip`) and the read-only checklist phones see (`#setup-mobile`), all
  rendered from `Relay.Setup.checklist/1` and re-rendered live on `{:setup_changed, board_id}`.
  """
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Agents
  alias Relay.ApiKeys
  alias Relay.Boards
  alias Relay.Repo
  alias Relay.Setup
  alias Schemas.Card
  alias Schemas.Stage
  alias Schemas.User

  setup :register_and_log_in_user

  defp create!(user, template, name \\ "Streaks") do
    {:ok, board} = Boards.create_board(user, %{name: name, slug: unique_slug("streaks"), template: template})
    board
  end

  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.replace(~r/\s+/, " ")
  end

  # The element's own attribute, not its descendants'.
  defp attr(view, selector, name) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.attribute(name) |> List.first()
  end

  defp token_in(view) do
    assert text(view, "#setup-key-box") =~ "export RELAY_API_KEY=relay_"
    "export RELAY_API_KEY=" <> token = view |> text("#setup-key-line code") |> String.trim()
    token
  end

  defp pick!(view, harness) do
    view |> element("#setup-llm-form") |> render_change(%{"llm" => harness})
    view |> element("#setup-use-llm") |> render_click()
    view
  end

  describe "a board created from a template" do
    # Scenario 1
    test "opens on the docked wizard beside the still-rendered board", %{conn: conn, user: user} do
      board = create!(user, "bare-minimum", "Streaks")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      panel = text(view, "#setup-panel")
      assert panel =~ "SETUP"
      assert panel =~ "2 of 7"
      assert panel =~ "Set up Streaks"

      step1 = text(view, "#setup-step-1")
      assert step1 =~ "Board created from Bare minimum"
      assert step1 =~ "6 stages · 2 flows"

      assert has_element?(view, "#setup-step-2 #setup-llm-form")
      assert has_element?(view, ~s(section[id^="category-"]))
      assert text(view, "#setup-chip") =~ "Setup · 2 of 7"
    end

    # Scenario 3
    test "step 2 offers the LLMs, Gemini disabled, and picking Codex mints the shown-once key",
         %{conn: conn, user: user} do
      board = create!(user, "bare-minimum")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#setup-llm-gemini-cli[disabled]")
      assert text(view, "#setup-step-2") =~ "coming soon"

      pick!(view, "codex")

      assert Agents.default_agent(board).harness.key == "codex"
      step2 = text(view, "#setup-step-2")
      assert step2 =~ "Default LLM: Codex"
      assert step2 =~ "chosen"
      assert text(view, "#setup-key-box") =~ "export RELAY_API_KEY=relay_"
      assert text(view, "#setup-step-5") =~ "Onboard, in Codex"
    end

    # Scenario 4
    test "a reload hides the key; minting a new one shows a fresh token and kills the first",
         %{conn: conn, user: user} do
      board = create!(user, "bare-minimum")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      first = view |> pick!("claude-code") |> token_in()

      {:ok, reloaded, _html} = live(conn, ~p"/board/#{board.slug}")
      refute has_element?(reloaded, "#setup-key-box")
      assert has_element?(reloaded, "#setup-mint-key")

      reloaded |> element("#setup-mint-key") |> render_click()
      second = token_in(reloaded)

      assert second != first
      assert ApiKeys.authenticate(first) == :error
      assert {:ok, _board} = ApiKeys.authenticate(second)
    end

    # Scenario 5
    test "step 4 shows the install command and names the default CLI in the then-row",
         %{conn: conn, user: user} do
      board = create!(user, "bare-minimum")
      {:ok, _} = Setup.advance(board, "2", :done, %{})
      {:ok, _} = Setup.advance(board, "3", :done, %{})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      install = text(view, "#setup-install-command")
      assert install =~ "curl -fsSL"
      assert install =~ "/b/#{board.slug}/install | sh"
      assert text(view, "#setup-then") =~ "Open claude in the same folder"
    end

    # Scenario 5 (after scenario 3's pick)
    test "step 4's then-row follows the step-2 pick", %{conn: conn, user: user} do
      board = create!(user, "bare-minimum")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      pick!(view, "codex")
      {:ok, _} = Setup.advance(board, "3", :done, %{})

      assert text(view, "#setup-then") =~ "Open codex in the same folder"
      assert text(view, "#setup-install-command") =~ "/b/#{board.slug}/install | sh"
    end

    # Scenario 6
    test "the failed preflight and the finished install re-render live", %{conn: conn, user: user} do
      board = create!(user, "bare-minimum")
      {:ok, _} = Setup.advance(board, "2", :done, %{})
      {:ok, _} = Setup.advance(board, "3", :done, %{})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      {:ok, _} =
        Setup.advance(board, "4", :failed, %{
          error: "Preflight stopped: Claude Code isn't on your PATH",
          data: %{
            "checks" => [%{"id" => "cli", "label" => "claude on PATH", "ok" => false, "detail" => "not found"}],
            "fix" => "Install it…",
            "fix_command" => "npm install -g @anthropic-ai/claude-code"
          }
        })

      step4 = text(view, "#setup-step-4")
      assert step4 =~ "Preflight stopped: Claude Code isn't on your PATH"
      assert step4 =~ "npm install -g @anthropic-ai/claude-code"
      checks = text(view, "#setup-preflight-checks")
      assert checks =~ "claude on PATH"
      assert checks =~ "not found"

      {:ok, _} = Setup.advance(board, "4", :waiting, %{evidence: "preflight passed 14:10 · jl-mbp"})
      {:ok, _} = Setup.advance(board, "4", :done, %{evidence: "downloaded 14:11 · ~/src/x · main"})

      assert text(view, "#setup-step-4") =~ "✓ downloaded"
      assert has_element?(view, ~s(#setup-step-5[data-status="active"]))
    end

    # Scenario 7
    test "minimize hides the panel and keeps the chip; the chip reopens it", %{conn: conn, user: user} do
      board = create!(user, "bare-minimum")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#setup-minimize") |> render_click()
      refute has_element?(view, "#setup-panel")
      assert has_element?(view, "#setup-chip")

      view |> element("#setup-chip") |> render_click()
      assert has_element?(view, "#setup-panel")
    end

    # Scenario 8
    test "the expert toggle hides explanations and persists on the user", %{conn: conn, user: user} do
      board = create!(user, "bare-minimum")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(view, "#setup-how-relay-works")
      assert has_element?(view, "#setup-panel .setup-why")

      view |> element("#setup-explanations-toggle") |> render_click()

      refute has_element?(view, "#setup-how-relay-works")
      refute has_element?(view, "#setup-panel .setup-why")
      assert Repo.get!(User, user.id).setup_explanations_hidden

      {:ok, reloaded, _html} = live(conn, ~p"/board/#{board.slug}")
      refute has_element?(reloaded, "#setup-how-relay-works")
      refute has_element?(reloaded, "#setup-panel .setup-why")
    end

    # Scenario 9
    test "phones get a read-only checklist instead of the columns", %{conn: conn, user: user} do
      board = create!(user, "bare-minimum")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert text(view, "#setup-continue-banner") =~ "Continue on a computer"
      refute has_element?(view, "#setup-mobile #setup-llm-form")
      refute has_element?(view, "#setup-mobile #setup-key-box")
      refute has_element?(view, "#setup-mobile #setup-install-command")
      refute has_element?(view, "#setup-mobile button")
      refute has_element?(view, "#setup-mobile input")
      assert text(view, "#setup-mobile-checklist-step-3") =~ "Needs a computer"
      assert text(view, "#setup-mobile") =~ "The board appears here once setup is done."

      assert has_element?(view, "#setup-mobile.drawer\\:hidden")
      assert has_element?(view, "#board-bands.hidden.drawer\\:flex")
      refute attr(view, "#board-bands", "style") =~ "display:flex"
      assert has_element?(view, "#board-pager-nav.hidden")
      assert has_element?(view, "#setup-panel.hidden.drawer\\:flex")
    end

    # Scenario 10
    test "a three-brain board warns about its three LLMs on step 2", %{conn: conn, user: user} do
      three = create!(user, "three-brain")
      {:ok, view, _html} = live(conn, ~p"/board/#{three.slug}")
      assert text(view, "#setup-template-warning") =~ "Three-brain boards run Claude Code, Codex and Gemini"

      bare = create!(user, "bare-minimum")
      {:ok, bare_view, _html} = live(conn, ~p"/board/#{bare.slug}")
      refute has_element?(bare_view, "#setup-template-warning")
    end
  end

  describe "step 5's onboard loop (RE445)" do
    defp to_sub!(board, sub_ids) do
      for step <- ~w(2 3 4) ++ sub_ids, do: {:ok, _} = Setup.advance(board, step, :done, %{})
      board
    end

    # RE445 task 3, scenario 10
    test "a 5.3 answer report re-renders the answers block live", %{conn: conn, user: user} do
      board = user |> create!("bare-minimum") |> to_sub!(~w(5.1 5.2))
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      refute has_element?(view, "#setup-answers")

      {:ok, _} =
        Setup.advance(board, "5.3", :waiting, %{
          data: %{
            "answers" => %{
              "done" => "PR merged",
              "landing" => "PR into main",
              "deploy" => "stays human",
              "baton" => "plans + finished code"
            }
          }
        })

      assert view |> text("#setup-answers-count") |> String.trim() == "4 of 9"
      assert view |> text("#setup-question-next") |> String.trim() == "question 5 of 9 in your terminal…"
    end

    # RE445 task 3, scenario 11
    test "the waiting-for-PR block appears on 5.6 waiting and goes once 5.6 is done", %{conn: conn, user: user} do
      board = user |> create!("bare-minimum") |> to_sub!(~w(5.1 5.2 5.3 5.4 5.5))
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      refute has_element?(view, "#setup-onboard-pr")

      {:ok, _} =
        Setup.advance(board, "5.6", :waiting, %{
          evidence: "PR #12 open",
          data: %{"pr_url" => "https://github.com/jl/streaks/pull/12", "base" => "main"}
        })

      assert has_element?(view, ~s(#setup-onboard-pr-link[href="https://github.com/jl/streaks/pull/12"]))

      {:ok, _} = Setup.advance(board, "5.6", :done, %{evidence: "on origin/main"})

      refute has_element?(view, "#setup-onboard-pr")
      assert has_element?(view, ~s(#setup-step-5-6[data-status="done"]))
    end
  end

  describe "the payoff: step 7's first claim (RE446)" do
    # Every step a report moves, in catalog order: a parent with children is walked through them.
    defp walk do
      parents = for %{parent: parent} <- Setup.steps(), parent, into: MapSet.new(), do: parent
      for %{id: id} <- tl(Setup.steps()), id not in parents, do: id
    end

    # Moves the board's checklist to step `id` by finishing every reportable step before it.
    defp advance_to!(board, id) do
      for prior <- Enum.take_while(walk(), &(&1 != id)), do: {:ok, _} = Setup.advance(board, prior, :done, %{})
      board
    end

    defp top_ids, do: for(%{parent: nil, id: id} <- Setup.steps(), do: id)

    # A bare-minimum board walked to step 7, then finished by a claim of a real card on it.
    defp finished!(user) do
      board = user |> create!("bare-minimum") |> advance_to!(Setup.step_id(:first_claim))
      stage = Repo.one!(from(s in Stage, where: s.board_id == ^board.id, order_by: s.position, limit: 1))
      card = insert(:card, stage: stage, title: "Streak counter")
      ref = Card.format_ref(board.key, card.ref_number)

      {:ok, _} =
        Setup.advance(board, Setup.step_id(:first_claim), :done, %{
          evidence: "#{ref} claimed 14:12 by jl-mbp",
          data: %{
            "card_ref" => ref,
            "card_id" => card.id,
            "runner" => "jl-mbp",
            "machine" => "jl-mbp",
            "verb" => "planning"
          }
        })

      %{board: board, card: card, ref: ref}
    end

    defp gone?(view), do: Enum.map(~w(#setup-callout #setup-panel #setup-chip), &has_element?(view, &1))

    # Scenario 1
    test "the claimed card gets the baton callout", %{conn: conn, user: user} do
      %{board: board, ref: ref} = finished!(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert attr(view, "#setup-callout", "data-card-ref") == ref
      callout = text(view, "#setup-callout")
      assert callout =~ "An agent has the baton"
      assert callout =~ "#{ref} just turned violet: your runner on jl-mbp claimed it and Claude Code is planning it now."

      assert callout =~
               "When it needs you (a plan to approve, a question, a review) it comes back blue and shows up in Needs you."

      assert view |> text("#setup-callout-watch") |> String.trim() == "Watch it work"
      assert view |> text("#setup-callout-dismiss") |> String.trim() == "Got it"
    end

    # Scenario 2
    test "the panel shows the You're set up box, 7 of 7, and the chip reads done", %{conn: conn, user: user} do
      %{board: board} = finished!(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      checklist = Setup.checklist(board)

      done = text(view, "#setup-panel #setup-done")
      assert done =~ "You're set up. #{checklist.elapsed_minutes} minutes."
      assert done =~ "Reopen it any time from Board settings → Setup."
      assert view |> text("#setup-done #setup-close") |> String.trim() == "Close setup"
      assert view |> text("#setup-done #setup-connect-another") |> String.trim() == "➕ Connect another machine"
      assert text(view, "#setup-panel") =~ "#{checklist.total} of #{checklist.total}"
      assert view |> text("#setup-chip") |> String.trim() == "Setup · done"
    end

    # Scenario 3
    test "steps 6 and 7 read Runner online and First card claimed", %{conn: conn, user: user} do
      %{board: board, ref: ref} = finished!(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert text(view, "#setup-step-6") =~ "Runner online"
      step7 = text(view, "#setup-step-7")
      assert step7 =~ "First card claimed"
      assert step7 =~ "#{ref} claimed 14:12 by jl-mbp"
    end

    # Scenario 4
    test "Watch it work opens the card and removes every piece of setup chrome", %{conn: conn, user: user} do
      %{board: board, card: card, ref: ref} = finished!(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#setup-callout-watch") |> render_click()

      assert_patch(view, "/board/#{board.slug}?card=#{ref}")
      assert text(view, "#card-drawer") =~ card.title
      assert gone?(view) == [false, false, false]
    end

    # Scenario 5
    test "Got it closes setup", %{conn: conn, user: user} do
      %{board: board} = finished!(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#setup-callout-dismiss") |> render_click()

      assert gone?(view) == [false, false, false]
      assert Setup.checklist(board).closed?
    end

    # Scenario 6
    test "Close setup stays closed across a remount", %{conn: conn, user: user} do
      %{board: board} = finished!(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#setup-close") |> render_click()

      {:ok, remounted, _html} = live(conn, ~p"/board/#{board.slug}")
      refute has_element?(remounted, "#setup-panel")
      refute has_element?(remounted, "#setup-chip")
      refute has_element?(remounted, "#setup-callout")
      refute has_element?(remounted, "#setup-mobile")
    end

    # Scenario 7
    test "closing in one view removes the panel and chip from another", %{conn: conn, user: user} do
      %{board: board} = finished!(user)
      {:ok, first, _html} = live(conn, ~p"/board/#{board.slug}")
      {:ok, second, _html} = live(conn, ~p"/board/#{board.slug}")
      assert has_element?(second, "#setup-panel")

      first |> element("#setup-close") |> render_click()

      render(second)
      refute has_element?(second, "#setup-panel")
      refute has_element?(second, "#setup-chip")
    end

    # Scenario 8
    test "reopening brings the finished panel back without the callout", %{conn: conn, user: user} do
      %{board: board} = finished!(user)
      {:ok, _} = Setup.close(board)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      refute has_element?(view, "#setup-panel")

      {:ok, _} = Setup.reopen(board)

      assert has_element?(view, "#setup-panel")
      for id <- top_ids(), do: assert(has_element?(view, ~s(#setup-step-#{id}[data-status="done"])))
      refute has_element?(view, "#setup-callout")
    end

    # Scenario 9
    test "a finished setup keeps the columns on phones", %{conn: conn, user: user} do
      %{board: board} = finished!(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      refute has_element?(view, "#setup-mobile")
      assert has_element?(view, "#setup-panel")
      assert attr(view, "#board-bands", "style") =~ "display:flex"
      refute has_element?(view, "#board-pager-nav.hidden")
    end

    # Scenario 10
    test "Connect another machine patches to ?setup=connect", %{conn: conn, user: user} do
      %{board: board} = finished!(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#setup-connect-another") |> render_click()

      assert_patch(view, "/board/#{board.slug}?setup=connect")
    end
  end

  # Scenario 2
  describe "a board with no checklist" do
    test "renders no wizard, chip or mobile checklist", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      refute has_element?(view, "#setup-panel")
      refute has_element?(view, "#setup-chip")
      refute has_element?(view, "#setup-mobile")
      assert attr(view, "#board-bands", "style") =~ "display:flex"
      refute has_element?(view, "#board-pager-nav.hidden")
    end
  end
end
