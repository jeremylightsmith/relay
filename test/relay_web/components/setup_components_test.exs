defmodule RelayWeb.SetupComponentsTest do
  @moduledoc """
  RE443 task 4: `RelayWeb.SetupComponents.setup_checklist/1` — one marker per step state. RE445
  task 3: step 5's body — the sub-step rows, elapsed time, answers, changes, PR wait and failed
  blocks (card mockup frames D, F1, F2, E).
  """
  use Relay.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Setup
  alias RelayWeb.SetupComponents
  alias Schemas.BoardSetupStep

  # A real checklist with its first six top-level steps forced into each of the six statuses,
  # in the order step 1 done, 2 active, 3 waiting, 4 failed, 5 pending, 6 skipped.
  defp every_state_checklist do
    {:ok, board} =
      Boards.create_board(insert(:user), %{name: "S", slug: unique_slug("setup"), template: "bare-minimum"})

    [pending, active, waiting, done, failed, skipped] = BoardSetupStep.statuses()
    top_ids = for %{parent: nil, id: id} <- Setup.steps(), do: id
    by_step = Map.new(Enum.zip(top_ids, [done, active, waiting, failed, pending, skipped]))

    checklist = Setup.checklist(board)

    steps =
      Enum.map(checklist.steps, fn step ->
        case by_step[step.id] do
          nil -> step
          :waiting -> %{step | status: :waiting, evidence: "preflight passed 14:10 · jl-mbp"}
          :failed -> %{step | status: :failed, evidence: "preflight failed 14:07", error: "Preflight stopped"}
          status -> %{step | status: status}
        end
      end)

    %{checklist | steps: steps}
  end

  defp marker(doc, step_id) do
    [marker] = doc |> LazyHTML.query("#c-step-#{step_id} > .setup-marker-col > .setup-marker") |> Enum.to_list()
    {marker |> LazyHTML.text() |> String.trim(), marker |> LazyHTML.attribute("style") |> List.first()}
  end

  # Scenario 11
  test "renders one marker per step state" do
    checklist = every_state_checklist()
    html = render_component(&SetupComponents.setup_checklist/1, id: "c", checklist: checklist)
    doc = LazyHTML.from_fragment(html)

    {text, style} = marker(doc, "1")
    assert text == "✓"
    assert style =~ "background:var(--color-success)"

    {text, style} = marker(doc, "2")
    assert text == "2"
    assert style =~ "background:var(--color-primary)"
    assert style =~ "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-primary) 18%, var(--color-base-100))"

    {_text, style} = marker(doc, "3")
    assert style =~ "box-shadow:0 0 0 4px"
    assert doc |> LazyHTML.query("#c-step-3 .setup-evidence.animate-pulse") |> Enum.count() == 1

    {text, style} = marker(doc, "4")
    assert text == "!"
    assert style =~ "background:var(--color-error)"

    {text, style} = marker(doc, "5")
    assert text == "5"
    assert style =~ "border:1.5px solid var(--color-base-300)"
    refute style =~ "dashed"

    {_text, style} = marker(doc, "6")
    assert style =~ "border-style:dashed"

    [tag] = doc |> LazyHTML.query("#c-step-5 .setup-actor-tag") |> Enum.to_list()
    assert tag |> LazyHTML.text() |> String.trim() == "AI · terminal"
    assert tag |> LazyHTML.attribute("style") |> List.first() =~ "var(--color-secondary)"
  end

  # Scenario 11
  test "read-only mode renders no button and no input" do
    html =
      render_component(&SetupComponents.setup_checklist/1,
        id: "c",
        checklist: every_state_checklist(),
        mode: :read_only,
        token: "relay_secret",
        install_command: "curl -fsSL http://x/b/s/install | sh"
      )

    doc = LazyHTML.from_fragment(html)
    assert doc |> LazyHTML.query("button") |> Enum.count() == 0
    assert doc |> LazyHTML.query("input") |> Enum.count() == 0
    refute html =~ "relay_secret"
    refute html =~ "curl -fsSL"
  end

  describe "step 5's body (RE445)" do
    @now ~U[2026-10-12 14:40:00Z]

    defp onboard_doc(rows, opts \\ []) do
      checklist = Setup.preview_checklist(rows, %{template: "Bare minimum", llm: Setup.onboarding_llm("claude-code")})

      html =
        render_component(
          &SetupComponents.setup_checklist/1,
          Keyword.merge([id: "setup", checklist: checklist, now: @now], opts)
        )

      LazyHTML.from_fragment(html)
    end

    defp first_four_done, do: Map.new(~w(1 2 3 4), &{&1, :done})

    defp q(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.to_list()

    defp has?(doc, selector), do: q(doc, selector) != []

    defp text(doc, selector) do
      [node] = q(doc, selector)
      node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()
    end

    defp style(doc, selector) do
      [node] = q(doc, selector)
      node |> LazyHTML.attribute("style") |> List.first()
    end

    defp class(doc, selector) do
      [node] = q(doc, selector)
      node |> LazyHTML.attribute("class") |> List.first()
    end

    defp glyph(doc, sub), do: text(doc, "#setup-step-#{sub} .setup-substep-glyph")

    defp evidence(doc, sub), do: text(doc, "#setup-step-#{sub} .setup-substep-evidence")

    defp frame_d do
      Map.merge(first_four_done(), %{
        "5" => %{status: :active, reached_at: DateTime.add(@now, -12 * 60)},
        "5.1" => %{status: :done, evidence: "2 flows"},
        "5.2" => %{status: :done, evidence: "elixir · mix precommit"},
        "5.3" => %{status: :done, evidence: "9 of 9 answered"},
        "5.4" => %{status: :done, evidence: "dropped screenshots"},
        "5.5" => %{status: :done, evidence: "enabled"},
        "5.6" => %{
          status: :waiting,
          evidence: "PR #12 open · checked 14:31",
          data: %{"pr_url" => "https://github.com/jl/streaks/pull/12", "base" => "main"}
        }
      })
    end

    @four_answers %{
      "done" => "PR merged",
      "landing" => "PR into main",
      "deploy" => "stays human",
      "baton" => "plans + finished code"
    }

    # Scenario 1
    test "frame D: elapsed time, the waiting-for-PR block and the sub-step glyphs" do
      doc = onboard_doc(frame_d())

      assert text(doc, "#setup-onboard-elapsed") == "12 min"

      pr = text(doc, "#setup-onboard-pr")
      assert pr =~ "Waiting for your PR to merge"
      assert pr =~ "The runner can't work until these files are on origin/main."
      assert style(doc, "#setup-onboard-pr") =~ "var(--color-secondary) 7%"

      [link] = q(doc, "#setup-onboard-pr-link")
      assert LazyHTML.attribute(link, "href") == ["https://github.com/jl/streaks/pull/12"]
      assert LazyHTML.attribute(link, "target") == ["_blank"]
      assert LazyHTML.attribute(link, "rel") == ["noopener noreferrer"]
      assert text(doc, "#setup-onboard-pr-link") == "github.com/jl/streaks/pull/12"

      assert glyph(doc, "5-1") == "✓"
      assert style(doc, "#setup-step-5-1 .setup-substep-glyph") =~ "var(--color-success) 70%"
      assert evidence(doc, "5-1") == "2 flows"
      assert glyph(doc, "5-6") == "◌"
      assert class(doc, "#setup-step-5-6 .setup-substep-glyph") =~ "animate-pulse"
      assert glyph(doc, "5-7") == "○"

      refute has?(doc, "#setup-answers")
      refute has?(doc, "#setup-changes")
    end

    # RE447 task 3, scenario 9
    test "5.4's row shows the missing-files progress while it resolves them" do
      doc =
        onboard_doc(
          Map.merge(frame_d(), %{
            "5.4" => %{status: :waiting, evidence: "missing files 2 of 9 resolved"},
            "5.5" => :pending,
            "5.6" => :pending
          }),
          mode: :interactive
        )

      assert text(doc, "#setup-step-5-4") =~ "missing files 2 of 9 resolved"
    end

    # Scenario 2
    test "frame F1: the answers so far, the next question and where they're saved" do
      doc =
        onboard_doc(
          Map.merge(first_four_done(), %{
            "5" => :active,
            "5.1" => :done,
            "5.2" => :done,
            "5.3" => %{status: :waiting, data: %{"answers" => @four_answers}}
          })
        )

      assert has?(doc, "details#setup-answers[open]")
      assert text(doc, "#setup-answers-count") == "4 of 9"

      rows =
        doc
        |> q("#setup-answers [id^='setup-answer-']")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first()))

      assert rows == ~w(setup-answer-done setup-answer-landing setup-answer-deploy setup-answer-baton)
      assert text(doc, "#setup-answer-done") == "Done means PR merged"
      assert text(doc, "#setup-answer-landing") == "Changes land PR into main"
      assert text(doc, "#setup-answer-deploy") == "Deploy stays human"
      assert text(doc, "#setup-answer-baton") == "Baton back plans + finished code"

      assert text(doc, "#setup-question-next") == "question 5 of 9 in your terminal…"
      assert text(doc, "#setup-project-md") == "→ .relay/project.md (committed in 5.6) · copy kept on the board"
      assert glyph(doc, "5-3") == "◌"
    end

    # Scenario 3
    test "5.3 active with no answers yet shows no answers block" do
      doc =
        onboard_doc(Map.merge(first_four_done(), %{"5" => :active, "5.1" => :done, "5.2" => :done, "5.3" => :active}))

      refute has?(doc, "#setup-answers")
      assert glyph(doc, "5-3") == "▸"
      assert style(doc, "#setup-step-5-3 .setup-substep-glyph") =~ "var(--color-secondary) 70%"
    end

    # Scenario 4
    test "frame F2: every proposed change with its agreement marker" do
      answers =
        Map.merge(@four_answers, %{
          "ui" => "mix phx.server · :4000",
          "never_touch" => "priv/repo/migrations",
          "warm_up" => "_build, deps",
          "capacity" => "2 cards",
          "misfits" => "none"
        })

      changes = [
        %{"summary" => "validate: `mix test` → `mix precommit`", "decision" => "accepted"},
        %{"summary" => "drop `screenshots` node from implement", "decision" => "rejected"},
        %{"summary" => "runner.json: capacity 3 → 2", "decision" => "edited", "note" => "→ 2, limit 60%"},
        %{"summary" => "warm-up hook: copy `_build`, `deps`", "decision" => "asking"},
        %{"summary" => "never-touch list → every flow prompt", "decision" => "pending"}
      ]

      doc =
        onboard_doc(
          Map.merge(first_four_done(), %{
            "5" => :active,
            "5.1" => :done,
            "5.2" => :done,
            "5.3" => %{status: :done, data: %{"answers" => answers}},
            "5.4" => %{status: :waiting, data: %{"changes" => changes}}
          })
        )

      assert text(doc, "#setup-answers-count") == "9 of 9"
      refute has?(doc, "#setup-question-next")

      assert text(doc, "#setup-changes-header") == "5 proposed changes · agreeing one at a time"

      expected = [
        {1, "accepted", "✓", "accepted"},
        {2, "rejected", "✕", "rejected"},
        {3, "edited", "✎", "→ 2, limit 60%"},
        {4, "asking", "▸", "asking you now"},
        {5, "pending", "○", ""}
      ]

      for {i, decision, glyph, label} <- expected do
        assert has?(doc, ~s(#setup-change-#{i}[data-decision="#{decision}"]))
        assert text(doc, "#setup-change-#{i} .setup-change-glyph") == glyph
        assert text(doc, "#setup-change-#{i} .setup-change-label") == label
      end

      codes = doc |> q("#setup-change-1 code") |> Enum.map(&LazyHTML.text/1)
      assert codes == ["mix test", "mix precommit"]
      assert text(doc, "#setup-change-1 .setup-change-summary") == "validate: mix test → mix precommit"

      assert text(doc, "#setup-changes-note") ==
               "Nothing is changed until all 5 are decided. Then only the accepted ones are applied."
    end

    # Scenario 4 (Risks: escaped, and a stray backtick stays literal)
    test "a change summary is escaped and an odd backtick renders literally" do
      changes = [%{"summary" => "use `<b>` tags `here", "decision" => "pending"}]

      doc =
        onboard_doc(
          Map.merge(first_four_done(), %{
            "5" => :active,
            "5.1" => :done,
            "5.2" => :done,
            "5.3" => %{status: :done, data: %{"answers" => @four_answers}},
            "5.4" => %{status: :waiting, data: %{"changes" => changes}}
          })
        )

      refute has?(doc, "#setup-change-1 b")
      assert doc |> q("#setup-change-1 code") |> Enum.map(&LazyHTML.text/1) == ["<b>"]
      assert text(doc, "#setup-change-1 .setup-change-summary") == "use <b> tags `here"
    end

    # Scenario 5
    test "frame E: the failed sub-step block" do
      doc =
        onboard_doc(
          Map.merge(first_four_done(), %{
            "5" => :active,
            "5.1" => :done,
            "5.2" => :done,
            "5.3" => :done,
            "5.4" => :done,
            "5.5" => %{
              status: :failed,
              error: "422 flow “implement”: node validate has no command",
              evidence: "422 · attempt 3/3",
              data: %{"attempts" => 3}
            }
          })
        )

      failed = text(doc, "#setup-onboard-failed")
      assert failed =~ "5.5 failed 3 times, now asking you in the terminal"
      assert failed =~ "422 flow “implement”: node validate has no command"
      assert style(doc, "#setup-onboard-failed") =~ "var(--color-error) 7%"

      assert glyph(doc, "5-5") == "!"
      assert style(doc, "#setup-step-5-5 .setup-substep-glyph") =~ "var(--color-error) 70%"
      assert evidence(doc, "5-5") == "422 · attempt 3/3"
    end

    # Scenario 6
    test "a failed sub-step with no attempts reads 1 time" do
      doc =
        onboard_doc(Map.merge(first_four_done(), %{"5" => :active, "5.1" => %{status: :failed, error: "boom"}}))

      assert text(doc, "#setup-onboard-failed") =~ "5.1 failed 1 time, now asking you in the terminal"
    end

    # Scenario 7
    test "read-only mode renders the sub-step list only" do
      doc = onboard_doc(frame_d(), mode: :read_only)

      for n <- 1..8, do: assert(has?(doc, "#setup-step-5-#{n} .setup-substep-glyph"))
      assert glyph(doc, "5-1") == "✓"
      assert evidence(doc, "5-1") == "2 flows"
      assert glyph(doc, "5-6") == "◌"

      refute has?(doc, "#setup-onboard-pr")
      refute has?(doc, "#setup-answers")
      refute has?(doc, "#setup-changes")
      refute has?(doc, "#setup-onboard-elapsed")
    end

    # Scenario 8
    test "step 5 pending: faint sub-step titles with ○ and no elapsed time" do
      doc = onboard_doc(%{"1" => :done, "2" => :active})

      for n <- 1..8 do
        assert glyph(doc, "5-#{n}") == "○"
        assert style(doc, "#setup-step-5-#{n} .setup-substep-title-cell") =~ "var(--color-base-content) 40%"
      end

      refute has?(doc, "#setup-onboard-elapsed")
    end

    # Scenario 9
    test "step 5's why names the CLI and the sub-steps carry the mockup's titles" do
      doc = onboard_doc(Map.put(first_four_done(), "5", :active))

      assert text(doc, "#setup-step-5 .setup-why") ==
               "Open claude in your repo and run /relay-onboard. It works this list until it's green and asks you in the chat when it's stuck."

      assert text(doc, "#setup-step-5-1 .setup-substep-title") == "Pull flows into .relay/flows/"
    end
  end

  describe "the payoff (RE446)" do
    defp preview(rows),
      do: Setup.preview_checklist(rows, %{template: "Bare minimum", llm: Setup.onboarding_llm("claude-code")})

    defp all_done, do: Map.new(Setup.steps(), &{&1.id, :done})

    defp callout_doc do
      callout = %{card_ref: "STR1", card_id: 1, machine: "jl-mbp", llm: "Claude Code", verb: "building"}

      (&SetupComponents.setup_callout/1)
      |> render_component(id: "setup-callout", callout: callout)
      |> LazyHTML.from_fragment()
    end

    defp first_attr(doc, selector, name), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()

    # Scenario 11
    test "setup_callout/1 carries the hook, the card ref, the verb and the two buttons" do
      doc = callout_doc()

      # The colocated `.SetupCallout` renders qualified by its module.
      assert first_attr(doc, "#setup-callout", "phx-hook") == "RelayWeb.SetupComponents.SetupCallout"
      assert first_attr(doc, "#setup-callout", "data-card-ref") == "STR1"
      assert doc |> LazyHTML.query("#setup-callout") |> LazyHTML.text() =~ "Claude Code is building it now"
      assert first_attr(doc, "#setup-callout-watch", "class") == "btn btn-secondary btn-sm"
      assert first_attr(doc, "#setup-callout-dismiss", "class") == "btn btn-ghost btn-sm"
    end

    # Scenario 12
    test "setup_chip/1 reads done once finished, else its position of the total" do
      chip = fn checklist ->
        (&SetupComponents.setup_chip/1)
        |> render_component(id: "setup-chip", checklist: checklist)
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.trim()
      end

      assert chip.(preview(all_done())) == "Setup · done"
      assert chip.(preview(%{"1" => :done, "2" => :done, "3" => :done, "4" => :active})) == "Setup · 4 of 7"
    end

    test "setup_done_box/1 says 1 minute, singular" do
      checklist = %{preview(all_done()) | elapsed_minutes: 1}

      text =
        (&SetupComponents.setup_done_box/1)
        |> render_component(id: "setup-done", checklist: checklist)
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert text =~ "You're set up. 1 minute."
    end
  end

  describe "connect a machine (RE446)" do
    defp connect_board do
      owner = insert(:user, name: "Jeremy")

      {:ok, board} =
        Boards.create_board(owner, %{name: "Streaks", slug: unique_slug("streaks"), template: "bare-minimum"})

      {:ok, _} = Setup.choose_llm(board, owner, "claude-code")
      board
    end

    defp substep_ids(html, list_id) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("##{list_id}-step-5 li[id]")
      |> LazyHTML.attribute("id")
    end

    # Scenario 13
    test "an unsaved connect renders only the sub-steps a machine runs; a board's renders all eight" do
      board = connect_board()
      connect = Setup.connect_checklist(board, insert(:user, name: "Sam"))
      assert connect.machine_id == nil

      html = render_component(&SetupComponents.setup_checklist/1, id: "c", checklist: connect)
      assert substep_ids(html, "c") == ["c-step-5-1", "c-step-5-6"]

      html = render_component(&SetupComponents.setup_checklist/1, id: "c", checklist: Setup.checklist(board))
      onboard = Setup.step_id(:onboard)
      all = for %{parent: ^onboard, id: id} <- Setup.steps(), do: "c-step-" <> String.replace(id, ".", "-")
      assert length(all) == 8
      assert substep_ids(html, "c") == all
    end

    test "the connect panel's member note initials the signed-in person's name" do
      board = connect_board()
      connect = Setup.connect_checklist(board, insert(:user, name: "Jeremy Lightsmith"))

      text =
        (&SetupComponents.setup_panel/1)
        |> render_component(id: "setup-panel", checklist: connect, board_name: "Streaks", user_name: "Jeremy Lightsmith")
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#setup-member-note")
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      assert text =~ ~r/^JL Signed in as Jeremy Lightsmith, a member of Streaks\./
    end
  end
end
