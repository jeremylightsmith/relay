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

  describe ~s{step 3's "I've saved it — next" and "Lost it?" (RE455)} do
    @saved_evidence "saved 14:02 · confirmed when the install script calls in"

    defp key_doc(rows, opts) do
      {context, opts} = Keyword.pop(opts, :context, %{})
      context = Map.merge(%{template: "Bare minimum", llm: Setup.onboarding_llm("claude-code")}, context)
      checklist = Setup.preview_checklist(rows, context)

      (&SetupComponents.setup_checklist/1)
      |> render_component(Keyword.merge([id: "setup", checklist: checklist], opts))
      |> LazyHTML.from_fragment()
    end

    defp key_active, do: %{"1" => :done, "2" => :done, "3" => :active}

    defp key_saved(data \\ %{"saved" => true}),
      do: %{"1" => :done, "2" => :done, "3" => %{status: :done, evidence: @saved_evidence, data: data}, "4" => :active}

    defp nodes(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.to_list()

    defp one(doc, selector) do
      [node] = nodes(doc, selector)
      node
    end

    defp attr_of(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

    defp text_of(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

    # Scenario 1
    test "the shown-once key has an \"I've saved it — next\" button after the key box" do
      doc = key_doc(key_active(), token: "relay_abc_123")

      assert nodes(doc, "#setup-key-box") != []
      button = one(doc, "#setup-key-saved")
      assert attr_of(button, "class") == "btn btn-primary btn-sm self-start"
      assert attr_of(button, "type") == "button"
      assert attr_of(button, "phx-click") == "setup_key_saved"
      assert text_of(button) == "I've saved it — next"

      ids = doc |> LazyHTML.query("#setup-key-box, #setup-key-saved") |> LazyHTML.attribute("id")
      assert ids == ["setup-key-box", "setup-key-saved"]
    end

    # Scenario 2
    test "no button without a token: the mint control shows instead" do
      doc = key_doc(key_active(), token: nil)
      assert nodes(doc, "#setup-key-saved") == []
      assert nodes(doc, "#setup-mint-key") != []
    end

    # Scenario 2
    test "an unsaved connect has no \"I've saved it\" button" do
      doc = key_doc(key_active(), token: nil, context: %{connect?: true, machine_id: nil})
      assert nodes(doc, "#setup-key-saved") == []
      assert nodes(doc, "#setup-mint-key") != []
    end

    # Scenario 3
    test "a saved-unconfirmed step 3 offers \"Lost it? Mint a new key\" under its evidence" do
      doc = key_doc(key_saved(), install_command: "curl -fsSL http://x/b/s/install | sh")

      lost = one(doc, "#setup-key-lost")
      assert text_of(lost) == "Lost it? Mint a new key"
      assert attr_of(lost, "phx-click") == "setup_mint_key"
      assert attr_of(lost, "class") == "link link-hover text-[11.5px] self-start"
      assert attr_of(lost, "style") =~ "color:color-mix(in oklab, var(--color-base-content) 55%, transparent)"

      assert doc |> one("#setup-step-3 .setup-evidence") |> text_of() == "✓ " <> @saved_evidence

      # A finished step's title row is its peek toggle (RE456).
      assert doc |> one("#setup-step-3 > div:nth-child(2) > :first-child > span:first-child") |> text_of() ==
               "Key in your environment"

      assert nodes(doc, "#setup-install-command") != []
    end

    # Scenario 4
    test "no \"Lost it?\" once the install confirmed the key" do
      doc = key_doc(key_saved(%{"saved" => true, "machine" => "jl-mbp"}), install_command: "curl x | sh")
      assert nodes(doc, "#setup-key-lost") == []
    end

    # Scenario 4
    test "no \"Lost it?\" for a step 3 confirmed the old way" do
      doc = key_doc(key_saved(%{}), install_command: "curl x | sh")
      assert nodes(doc, "#setup-key-lost") == []
    end

    # Scenario 4
    test "no \"Lost it?\" in read-only mode" do
      doc = key_doc(key_saved(), mode: :read_only)
      assert nodes(doc, "#setup-key-lost") == []
    end
  end

  describe "peek at a finished step (RE456)" do
    @key_hint %{token_prefix: "k7f2q9", last_four: "3a9c"}
    @install "curl -fsSL https://relayboard.fly.dev/b/acme-web/install | sh"
    @peek_shadow "box-shadow:inset 3px 0 0 color-mix(in oklab, var(--color-success) 55%, var(--color-base-100))"

    defp peek_context(context \\ %{}),
      do: Map.merge(%{template: "Bare minimum", llm: Setup.onboarding_llm("claude-code"), key_hint: @key_hint}, context)

    # Every step — the top-level 1–7 and step 5's sub-steps — done.
    defp finished(context \\ %{}),
      do: Setup.preview_checklist(Map.new(Setup.steps(), &{&1.id, :done}), peek_context(context))

    defp top_ids, do: for(%{parent: nil, id: id} <- Setup.steps(), do: id)

    defp peek_doc(opts) do
      {checklist, opts} = Keyword.pop_lazy(opts, :checklist, fn -> finished() end)
      opts = Keyword.update(opts, :peeks, MapSet.new(), &MapSet.new/1)

      (&SetupComponents.setup_checklist/1)
      |> render_component(Keyword.merge([id: "c", checklist: checklist], opts))
      |> LazyHTML.from_fragment()
    end

    defp all(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.to_list()

    defp present?(doc, selector), do: all(doc, selector) != []

    defp only(doc, selector) do
      [node] = all(doc, selector)
      node
    end

    defp attr1(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

    defp squish(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

    defp top_actor_tags(doc), do: all(doc, "#c > li > div > :first-child .setup-actor-tag")

    # Scenario 1
    test "every finished step's title row is a closed peek toggle, with no actor tag and no peek box" do
      doc = peek_doc(peeks: [])

      for id <- top_ids() do
        toggle = only(doc, "#c-step-#{id}-peek-toggle")
        assert attr1(toggle, "type") == "button"
        assert attr1(toggle, "aria-expanded") == "false"
        assert attr1(toggle, "phx-click") == "setup_toggle_peek"
        assert attr1(toggle, "phx-value-step") == id
        assert present?(doc, "#c-step-#{id}-peek-toggle .hero-chevron-right")
        refute present?(doc, "#c-step-#{id}-peek")
      end

      assert top_actor_tags(doc) == []
    end

    # Scenario 2
    test "an open peek: the toggle highlighted with a down chevron and its actor tag, the box still done" do
      doc = peek_doc(peeks: ["4"])

      toggle = only(doc, ~s(#c-step-4-peek-toggle[aria-expanded="true"]))
      assert attr1(toggle, "class") =~ ~r/(^|\s)bg-base-200(\s|$)/

      assert attr1(toggle, "class") =~
               "-mx-1.5 flex items-center gap-2 rounded-md px-1.5 py-0.5 text-left hover:bg-base-200"

      assert present?(doc, "#c-step-4-peek-toggle .hero-chevron-down")
      assert doc |> only("#c-step-4-peek-toggle .setup-actor-tag") |> squish() == "you · terminal"

      peek = only(doc, "#c-step-4-peek")
      assert squish(peek) =~ "still done · nothing here changes your progress"
      assert attr1(peek, "style") =~ @peek_shadow
      assert attr1(peek, "class") == "flex flex-col gap-2 rounded-lg border border-base-300 bg-base-100 p-3 mt-1"
      assert present?(doc, "#c-step-4-peek .hero-eye")

      assert attr1(only(doc, "#c-step-4"), "data-status") == "done"
      assert doc |> only("#c-step-4 > .setup-marker-col > .setup-marker") |> squish() == "✓"

      # Only the open step carries its tag.
      assert length(top_actor_tags(doc)) == 1
    end

    # Scenario 3
    test "step 4's peek: the install command, its rerun note, no then row, failure box or checks" do
      doc = peek_doc(peeks: ["4"], install_command: @install)

      assert doc |> only("#c-step-4-peek #c-install-command code") |> squish() == @install
      assert present?(doc, "#c-install-command-copy")
      assert squish(only(doc, "#c-step-4-peek")) =~ "Run it at the root of your repo"

      assert doc |> only("#c-install-rerun") |> squish() ==
               "Safe to run again: rewrites ./relay and the skill, keeps runner.json and prepare-worktree.sh"

      assert present?(doc, "#c-install-rerun .hero-arrow-path")

      refute present?(doc, "#c-then")
      refute present?(doc, "#c-install-failure")
      refute present?(doc, "#c-preflight-checks")
    end

    # Scenario 4
    test "step 3's peek masks the key, has no copy control and offers a new one" do
      doc = peek_doc(peeks: ["3"])

      assert doc |> only("#c-key-masked") |> squish() == "export RELAY_API_KEY=relay_k7f2q9_••••3a9c"
      refute present?(doc, "#c-key-masked button")
      refute present?(doc, ~s(#c-key-masked [id$="-copy"]))
      assert squish(only(doc, "#c-step-3-peek")) =~ "Masked: the board keeps only a hash, so there's nothing to copy."
      assert squish(only(doc, "#c-step-3-peek")) =~ "Where it went"

      mint = only(doc, ~s(#c-step-3-peek #c-mint-key[phx-click="setup_mint_key"]))
      assert squish(mint) == "Mint a new key"
      assert attr1(mint, "class") == "btn btn-sm self-start"

      assert squish(only(doc, "#c-step-3-peek")) =~
               "Lost it? Mint a new one. A key a runner already used keeps working until you revoke it in Board settings → API keys."

      refute present?(doc, "#c-key-box")
    end

    # Scenario 5
    test "step 3's peek shows a freshly minted key once, without the saved button" do
      doc = peek_doc(peeks: ["3"], token: "relay_newprefix_secret")

      assert squish(only(doc, "#c-step-3-peek #c-key-box")) =~ "Shown once. Copy it now."
      assert doc |> only("#c-key-line code") |> squish() == "export RELAY_API_KEY=relay_newprefix_secret"
      refute present?(doc, "#c-key-saved")
    end

    # Scenario 6
    test "step 3's peek without a key hint has no masked line, only the mint button" do
      doc = peek_doc(peeks: ["3"], checklist: finished(%{key_hint: nil}))

      refute present?(doc, "#c-key-masked")
      assert present?(doc, "#c-mint-key")
    end

    # Scenario 7
    test "step 2's peek: the picker with the current badge and a disabled default button" do
      doc = peek_doc(peeks: ["2"], selected_llm: "claude-code")

      assert present?(doc, "#c-step-2-peek #c-llm-form")
      assert attr1(only(doc, "#c-llm-form"), "phx-change") == "setup_select_llm"
      badge = only(doc, "#c-llm-claude-code-current")
      assert squish(badge) == "current"
      assert attr1(badge, "class") == "badge badge-ghost badge-xs"
      assert present?(doc, "#c-llm-gemini-cli[disabled]")

      button = only(doc, "#c-switch-llm[disabled]")
      assert squish(button) == "Claude Code is the default"
      assert attr1(button, "class") == "btn btn-sm self-start"
      assert squish(only(doc, "#c-step-2-peek")) =~ "The step stays done; its title follows the new default."

      refute present?(doc, "#c-use-llm")
    end

    # Scenario 8
    test "step 2's peek with another LLM picked offers to switch to it" do
      doc = peek_doc(peeks: ["2"], selected_llm: "codex")

      button = only(doc, "#c-switch-llm")
      assert attr1(button, "disabled") == nil
      assert squish(button) == "Switch to Codex"
      assert attr1(button, "class") == "btn btn-primary btn-sm self-start"
      assert attr1(button, "phx-click") == "setup_switch_llm"
      assert attr1(button, "phx-value-llm") == "codex"
      assert present?(doc, "#c-llm-claude-code-current")
      refute present?(doc, "#c-llm-codex-current")
    end

    # Scenario 9
    test "steps 5 and 6 peek at their commands; step 5's sub-steps stay" do
      doc = peek_doc(peeks: ["5", "6"])

      assert doc |> only("#c-step-5-peek #c-onboard-command code") |> squish() == "/relay-onboard"
      assert present?(doc, "#c-onboard-command-copy")
      for n <- 1..8, do: assert(present?(doc, "#c-step-5-#{n}"))

      assert doc |> only("#c-step-6-peek #c-runner-command code") |> squish() == "./relay start"
      assert present?(doc, "#c-runner-command-copy")
      assert doc |> only("#c-runner-restart") |> squish() == "Restart it after changing env vars or updating ./relay."

      # The peek sits before step 5's sub-step list.
      ids = doc |> LazyHTML.query("#c-step-5-peek, #c-step-5-1") |> LazyHTML.attribute("id")
      assert ids == ["c-step-5-peek", "c-step-5-1"]
    end

    # Scenario 10
    test "steps 1 and 7 peek at their why and What this does, no controls" do
      doc = peek_doc(peeks: ["1", "7"])

      peek = only(doc, "#c-step-1-peek")
      assert squish(peek) =~ "Your stages and flows, from the template. No cards yet."
      assert present?(doc, "#c-step-1-peek details.setup-what")
      refute present?(doc, "#c-step-1-peek details.setup-what[open]")
      refute present?(doc, "#c-step-1-peek button")
      refute present?(doc, "#c-step-1-peek code")
      assert present?(doc, "#c-step-7-peek")
    end

    # Scenario 11
    test "with explanations hidden a peek keeps its header but drops the why and What this does" do
      doc = peek_doc(peeks: ["1"], hide_explanations: true)

      peek = only(doc, "#c-step-1-peek")
      assert squish(peek) =~ "still done · nothing here changes your progress"
      refute present?(doc, "#c-step-1-peek .setup-what")
      refute squish(peek) =~ "Your stages and flows, from the template. No cards yet."
    end

    # Scenario 12
    test "step 5's sub-steps render with its peek closed" do
      doc = peek_doc(peeks: [])
      for n <- 1..8, do: assert(present?(doc, "#c-step-5-#{n}"))
    end

    # Scenario 13
    test "only finished steps get a toggle; the current step is unchanged" do
      checklist = Setup.preview_checklist(%{"1" => :done, "2" => :active}, peek_context())
      doc = peek_doc(checklist: checklist, peeks: ["2", "3"])

      assert present?(doc, "#c-step-1-peek-toggle")
      refute present?(doc, "#c-step-2-peek-toggle")
      refute present?(doc, "#c-step-3-peek-toggle")
      refute present?(doc, "#c-step-2-peek")
      refute present?(doc, "#c-step-3-peek")
      assert present?(doc, "#c-step-2 #c-use-llm")
    end

    # Scenario 14
    test "read-only mode has no toggle, no peek and no button" do
      doc = peek_doc(mode: :read_only, peeks: ["4"])

      refute present?(doc, ~s([id$="-peek-toggle"]))
      refute present?(doc, ~s([id$="-peek"]))
      refute present?(doc, "button")
    end

    # Scenario 15
    test "a connect's skipped steps get no toggle" do
      checklist =
        Setup.preview_checklist(
          %{"1" => :skipped, "2" => :skipped, "3" => :done, "4" => :active},
          peek_context(%{connect?: true, board_name: "acme-web", machine_id: 1})
        )

      doc = peek_doc(checklist: checklist, peeks: ["1", "2"])

      refute present?(doc, "#c-step-1-peek-toggle")
      refute present?(doc, "#c-step-2-peek-toggle")
      refute present?(doc, "#c-step-1-peek")
      assert present?(doc, "#c-step-3-peek-toggle")
    end

    # Scenario 16
    test "the done box says how to get a command back" do
      text =
        (&SetupComponents.setup_done_box/1)
        |> render_component(id: "setup-done", checklist: %{finished() | elapsed_minutes: 40})
        |> LazyHTML.from_fragment()
        |> squish()

      assert text =~ "Need a command again? Open any step below; it stays done."
      refute text =~ "Reopen it any time"
    end

    # Scenario 17
    test "setup_panel/1 hands its peeks to the checklist" do
      doc =
        (&SetupComponents.setup_panel/1)
        |> render_component(id: "setup-panel", checklist: finished(), board_name: "acme-web", peeks: MapSet.new(["4"]))
        |> LazyHTML.from_fragment()

      assert present?(doc, "#setup-step-4-peek")
      assert squish(only(doc, "#setup-done")) =~ "Need a command again? Open any step below; it stays done."
    end
  end
end
