defmodule RelayWeb.BoardLiveNeedsInputTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.Comment

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, backlog: backlog, code: code}
  end

  test "no panel renders for a card that does not need input", %{conn: conn, backlog: backlog, user: user} do
    {:ok, _card} = Cards.create_card(backlog, %{title: "Calm card"})

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#needs-input-panel")
  end

  test "the reply textarea sits in a full-width wrapper spanning the form",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Wide reply"})
    {:ok, _blocked} = Cards.request_input(card, "Which bucket?")

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    assert has_element?(view, "#needs-input-form > div.w-full #needs-input-answer")
  end

  test "a blocked card's drawer shows the amber panel with the latest question and composer",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Ship exports"})
    {:ok, _blocked} = Cards.request_input(card, "Billing timezone or the viewer's?")

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    assert has_element?(view, "#needs-input-panel", "RELAY AI NEEDS YOUR INPUT")
    assert has_element?(view, "#needs-input-question", "Billing timezone or the viewer's?")
    # RE279 — the wait time lives only in the blocked strip now
    refute has_element?(view, "#needs-input-waiting")
    assert has_element?(view, "#card-drawer-blocked-strip-wait-label", "waiting on you")

    # the question renders markdown as HTML, not literal text
    {:ok, mdcard} = Cards.create_card(code, %{title: "Markdown ask"})
    {:ok, _} = Cards.request_input(mdcard, "Use **UTC** or the `viewer` tz?")
    {:ok, mdview, _html} = live(conn, ~p"/board/#{board.slug}?card=MY#{mdcard.ref_number}")
    render_async(mdview)
    assert has_element?(mdview, "#needs-input-question.md strong", "UTC")
    assert has_element?(mdview, "#needs-input-question.md code", "viewer")
    assert has_element?(view, "#needs-input-answer")
    assert has_element?(view, "#needs-input-send", "Send to AI")
    assert has_element?(view, "#card-drawer-activity .timeline-activity-phrase", "asked for input")
  end

  test "re-asking shows the newest question, not the old one", %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Twice"})
    {:ok, card} = Cards.request_input(card, "First question?")
    {:ok, _card} = Cards.request_input(card, "Second question?")

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    assert has_element?(view, "#needs-input-question", "Second question?")
    refute has_element?(view, "#needs-input-question", "First question?")
  end

  test "answering closes the drawer, resumes the card to :working, and clears the amber badge (RLY-115)",
       %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Ship exports"})
    {:ok, _blocked} = Cards.request_input(card, "Which bucket?")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)
    assert has_element?(view, "#stage-col-#{code.position}-cards .card-needs-input", "needs you")

    view
    |> form("#needs-input-form", answer: %{body: "The relay-exports bucket"})
    |> render_submit()

    # the drawer closed back to the board — silently — and the tile's amber treatment is gone
    assert_patch(view, ~p"/board/#{board.slug}")
    refute has_element?(view, "#card-drawer")
    refute has_element?(view, "#flash-info")
    refute has_element?(view, "#stage-col-#{code.position}-cards .card-needs-input")

    reloaded = Cards.get_card_by_ref(board, "MY1")
    assert reloaded.status == :working
    assert reloaded.blocked_since == nil

    answer =
      reloaded
      |> Activity.list_timeline()
      |> Enum.find(&match?(%Comment{body: "The relay-exports bucket"}, &1))

    assert answer.actor_type == :user
  end

  test "answering a human-stage card closes the drawer and returns it to :ready",
       %{conn: conn, board: board, backlog: backlog} do
    {:ok, card} = Cards.create_card(backlog, %{title: "Human next"})
    {:ok, _blocked} = Cards.request_input(card, "Ready to start?")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    view |> form("#needs-input-form", answer: %{body: "Yes, go"}) |> render_submit()

    assert_patch(view, ~p"/board/#{board.slug}")
    refute has_element?(view, "#card-drawer")
    assert Cards.get_card_by_ref(board, "MY1").status == :ready
  end

  test "a human-blocked card (status control, no question) still gets the composer",
       %{conn: conn, backlog: backlog, user: user} do
    {:ok, card} = Cards.create_card(backlog, %{title: "Manual block"})
    {:ok, _blocked} = Cards.set_status(card, %{status: :needs_input})

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    assert has_element?(view, "#needs-input-panel")
    refute has_element?(view, "#needs-input-question")
    assert has_element?(view, "#needs-input-answer")
  end

  test "a blank answer is a no-op that keeps the panel", %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Still blocked"})
    {:ok, _blocked} = Cards.request_input(card, "Which bucket?")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    view |> form("#needs-input-form", answer: %{body: ""}) |> render_submit()

    assert has_element?(view, "#needs-input-panel")
    assert Cards.get_card_by_ref(board, "MY1").status == :needs_input
  end

  test "a request_input from elsewhere pops the panel into an open drawer live (MMF 18)",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Live block"})

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)
    refute has_element?(view, "#needs-input-panel")

    {:ok, _blocked} = Cards.request_input(card, "Which region?")

    assert has_element?(view, "#needs-input-panel", "Which region?")
  end

  test "a card_upserted that beats the :needs_input activity write still lands the question once the timeline_appended for it arrives (RLY-81 race)",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Race card"})
    {:ok, blocked} = Cards.set_status(card, %{status: :needs_input})

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    # Simulate `:card_upserted` winning the race against the `:needs_input` Activity
    # write: the card is already `:needs_input` in the DB, but no `:needs_input` entry
    # has been logged yet, so `refresh_card/2`'s question lookup comes back empty.
    send(view.pid, {:card_upserted, blocked})
    assert has_element?(view, "#needs-input-panel")
    refute has_element?(view, "#needs-input-question")

    {:ok, entry} =
      Activity.log(blocked, %{type: :needs_input, actor: :agent, meta: %{"question" => "Which region?"}})

    # The trailing `:timeline_appended` for that entry must recover the question rather
    # than leaving the panel permanently blank.
    send(view.pid, {:timeline_appended, card.id, entry})
    assert has_element?(view, "#needs-input-question", "Which region?")
  end

  defp structured_questions do
    [
      %{"prompt" => "Which timezone?", "options" => ["Billing", "Viewer"], "allow_text" => true},
      %{"prompt" => "Any size limit?", "options" => [], "allow_text" => true}
    ]
  end

  test "a structured block renders the stepper: progress, first prompt, option buttons",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Structured"})
    {:ok, _blocked} = Cards.request_input(card, structured_questions(), :agent)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    assert has_element?(view, "#needs-input-panel", "RELAY AI NEEDS YOUR INPUT")
    assert has_element?(view, "#needs-input-progress", "Question 1 of 2")
    assert has_element?(view, "#needs-input-question", "Which timezone?")
    assert has_element?(view, "#needs-input-option-0", "Billing")
    assert has_element?(view, "#needs-input-option-1", "Viewer")
    # first step has no Back and shows Next (not Send)
    refute has_element?(view, "#needs-input-back")
    assert has_element?(view, "#needs-input-next")
    refute has_element?(view, "#needs-input-send")
  end

  test "clicking an option advances to Q2; Back returns with the pick highlighted, Next re-advances, and a new pick advances again (AC6)",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Advance"})
    {:ok, _blocked} = Cards.request_input(card, structured_questions(), :agent)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    view |> element("#needs-input-option-1") |> render_click()

    assert has_element?(view, "#needs-input-progress", "Question 2 of 2")
    assert has_element?(view, "#needs-input-question", "Any size limit?")
    assert has_element?(view, "#needs-input-back")

    view |> element("#needs-input-back") |> render_click()
    assert has_element?(view, "#needs-input-progress", "Question 1 of 2")
    # the previously selected option keeps its selected marker
    assert has_element?(view, "#needs-input-option-1.needs-input-option-selected")

    # Next still advances a step whose answer is already recorded, without re-picking
    view |> element("#needs-input-next") |> render_click()
    assert has_element?(view, "#needs-input-progress", "Question 2 of 2")

    # and picking a different option after Back advances again
    view |> element("#needs-input-back") |> render_click()
    view |> element("#needs-input-option-0") |> render_click()
    assert has_element?(view, "#needs-input-progress", "Question 2 of 2")
    view |> element("#needs-input-back") |> render_click()
    assert has_element?(view, "#needs-input-option-0.needs-input-option-selected")
  end

  test "typing a custom answer records it for the step and enables advancing",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Custom"})
    {:ok, _blocked} = Cards.request_input(card, structured_questions(), :agent)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    view
    |> form("#needs-input-text-form", answer: %{index: "0", text: "Pacific"})
    |> render_change()

    refute has_element?(view, "#needs-input-next[disabled]")
  end

  test "Send on the last step composes one numbered Q->A comment, resumes :working, hides the panel",
       %{conn: conn, board: board, code: code} do
    {:ok, card} = Cards.create_card(code, %{title: "Send batch"})
    {:ok, _blocked} = Cards.request_input(card, structured_questions(), :agent)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    # Q1: picking an option commits the step and advances
    view |> element("#needs-input-option-0") |> render_click()
    assert has_element?(view, "#needs-input-progress", "Question 2 of 2")
    # Q2 (free-text only): type an answer, send
    view
    |> form("#needs-input-text-form", answer: %{index: "1", text: "Under 10 MB"})
    |> render_change()

    view |> element("#needs-input-send") |> render_click()

    # the drawer closed back to the board
    assert_patch(view, ~p"/board/#{board.slug}")
    refute has_element?(view, "#card-drawer")

    reloaded = Cards.get_card_by_ref(board, "MY1")
    assert reloaded.status == :working
    assert reloaded.blocked_since == nil

    composed = "1. Which timezone? → Billing\n2. Any size limit? → Under 10 MB"

    comment =
      reloaded
      |> Activity.list_timeline()
      |> Enum.find(&match?(%Comment{body: ^composed}, &1))

    assert comment.actor_type == :user

    # exactly one :input_answered activity
    answered =
      reloaded
      |> Activity.list_timeline()
      |> Enum.filter(&match?(%Schemas.Activity{type: :input_answered}, &1))

    assert length(answered) == 1
  end

  test "the amber Send button keeps the shipped panel's amber fill token",
       %{conn: conn, code: code, user: user} do
    {:ok, card} = Cards.create_card(code, %{title: "Amber"})
    {:ok, _blocked} = Cards.request_input(card, [%{"prompt" => "Only one?"}], :agent)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
    render_async(view)

    # single-question block: Send is on the first (only) step
    assert has_element?(view, "#needs-input-send[style*='background:var(--color-warning)']")
  end

  describe "RE323 commit a step in one action" do
    defp open_blocked(conn, board, code, questions) do
      {:ok, card} = Cards.create_card(code, %{title: "One action"})
      {:ok, card} = Cards.request_input(card, questions, :agent)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
      render_async(view)
      {view, card}
    end

    defp answer_comment(card, body) do
      card
      |> Relay.Repo.reload!()
      |> Activity.list_timeline()
      |> Enum.find(&match?(%Comment{body: ^body}, &1))
    end

    defp answered_count(card) do
      card
      |> Relay.Repo.reload!()
      |> Activity.list_timeline()
      |> Enum.count(&match?(%Schemas.Activity{type: :input_answered}, &1))
    end

    test "the textarea commits on ⌘/Ctrl+Enter via phx-submit and the SubmitOnCmdEnter hook",
         %{conn: conn, board: board, code: code} do
      {view, _card} = open_blocked(conn, board, code, structured_questions())

      assert has_element?(view, ~s|form#needs-input-text-form[phx-submit="answer_commit"]|)
      assert has_element?(view, ~s|textarea#needs-input-text[phx-hook="SubmitOnCmdEnter"]|)
    end

    test "clicking an option on a single-question batch sends it (AC1)",
         %{conn: conn, board: board, code: code} do
      questions = [%{"prompt" => "Pick one", "options" => ["Alpha", "Beta"], "allow_text" => true}]
      {view, card} = open_blocked(conn, board, code, questions)

      view |> element("#needs-input-option-1") |> render_click()

      assert_patch(view, ~p"/board/#{board.slug}")
      assert Relay.Repo.reload!(card).status == :working
      assert answer_comment(card, "1. Pick one → Beta")
      assert answered_count(card) == 1
    end

    test "on a two-question batch the first click advances and the second click sends (AC2)",
         %{conn: conn, board: board, code: code} do
      questions = [
        %{"prompt" => "Which timezone?", "options" => ["Billing", "Viewer"], "allow_text" => true},
        %{"prompt" => "Any size limit?", "options" => ["None", "10 MB"], "allow_text" => true}
      ]

      {view, card} = open_blocked(conn, board, code, questions)

      view |> element("#needs-input-option-0") |> render_click()

      assert has_element?(view, "#needs-input-progress", "Question 2 of 2")
      assert Relay.Repo.reload!(card).status == :needs_input
      assert answered_count(card) == 0

      view |> element("#needs-input-option-1") |> render_click()

      assert_patch(view, ~p"/board/#{board.slug}")
      assert answer_comment(card, "1. Which timezone? → Billing\n2. Any size limit? → 10 MB")
      assert answered_count(card) == 1
    end

    test "answer_commit with text advances on a non-final step and sends on the last (AC3/AC4)",
         %{conn: conn, board: board, code: code} do
      {view, card} = open_blocked(conn, board, code, structured_questions())

      view
      |> form("#needs-input-text-form", answer: %{index: "0", text: "Pacific"})
      |> render_submit()

      assert has_element?(view, "#needs-input-progress", "Question 2 of 2")
      assert answered_count(card) == 0

      view
      |> form("#needs-input-text-form", answer: %{index: "1", text: "Under 10 MB"})
      |> render_submit()

      assert_patch(view, ~p"/board/#{board.slug}")
      assert answer_comment(card, "1. Which timezone? → Pacific\n2. Any size limit? → Under 10 MB")
      assert answered_count(card) == 1
    end

    test "a blank answer_commit on an unanswered step is a no-op (AC5)",
         %{conn: conn, board: board, code: code} do
      questions = [%{"prompt" => "Describe it.", "options" => [], "allow_text" => true}]
      {view, card} = open_blocked(conn, board, code, questions)

      view
      |> form("#needs-input-text-form", answer: %{index: "0", text: "   "})
      |> render_submit()

      assert has_element?(view, "#needs-input-progress", "Question 1 of 1")
      assert Relay.Repo.reload!(card).status == :needs_input
      assert answered_count(card) == 0
    end

    test "a blank answer_commit on a step with a picked option commits that option",
         %{conn: conn, board: board, code: code} do
      {view, card} = open_blocked(conn, board, code, structured_questions())

      # pick Viewer (advances), go Back: the pick is still recorded for Q1
      view |> element("#needs-input-option-1") |> render_click()
      view |> element("#needs-input-back") |> render_click()
      assert has_element?(view, "#needs-input-option-1.needs-input-option-selected")

      view
      |> form("#needs-input-text-form", answer: %{index: "0", text: ""})
      |> render_submit()

      assert has_element?(view, "#needs-input-progress", "Question 2 of 2")

      view
      |> form("#needs-input-text-form", answer: %{index: "1", text: "None"})
      |> render_submit()

      assert answer_comment(card, "1. Which timezone? → Viewer\n2. Any size limit? → None")
    end

    test "a stale answer_select for an earlier step neither advances nor sends",
         %{conn: conn, board: board, code: code} do
      {view, card} = open_blocked(conn, board, code, structured_questions())

      view |> element("#needs-input-option-0") |> render_click()
      assert has_element?(view, "#needs-input-progress", "Question 2 of 2")

      # a click rendered for step 0 arriving while step 1 is on screen
      render_click(view, "answer_select", %{"index" => "0", "option" => "Viewer"})

      assert has_element?(view, "#needs-input-progress", "Question 2 of 2")
      assert Relay.Repo.reload!(card).status == :needs_input
      assert answered_count(card) == 0
    end

    test "answer_commit on a card that no longer needs input does nothing",
         %{conn: conn, board: board, code: code} do
      {:ok, calm} = Cards.create_card(code, %{title: "Calm"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, calm)}")
      render_async(view)

      render_hook(view, "answer_commit", %{"answer" => %{"index" => "0", "text" => "late"}})

      assert Relay.Repo.reload!(calm).status == calm.status
      refute answer_comment(calm, "1. late")
    end

    test "the textarea carries its step and the server text for that step, for the hook's reset",
         %{conn: conn, board: board, code: code} do
      {view, _card} = open_blocked(conn, board, code, structured_questions())

      assert has_element?(view, ~s|textarea#needs-input-text[data-step="0"][data-value=""]|)

      view
      |> form("#needs-input-text-form", answer: %{index: "0", text: "Pacific"})
      |> render_change()

      assert has_element?(view, ~s|textarea#needs-input-text[data-step="0"][data-value="Pacific"]|)

      view
      |> form("#needs-input-text-form", answer: %{index: "0", text: "Pacific"})
      |> render_submit()

      assert has_element?(view, ~s|textarea#needs-input-text[data-step="1"][data-value=""]|)
    end
  end

  describe "RE279 blocked strip" do
    defp open_card(conn, board, card) do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
      render_async(view)
      view
    end

    # AC1's seed: a card parked on a `spec` node with a genuine question, blocked 47 minutes ago.
    defp parked_on_spec(code, question) do
      {:ok, card} = Cards.create_card(code, %{title: "Board search"})
      {:ok, card} = Cards.request_input(card, question, :agent)

      {:ok, card} =
        card
        |> Ecto.Changeset.change(
          blocked_since: DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -47 * 60, :second)
        )
        |> Relay.Repo.update()

      run = insert(:run, card: card, flow_key: "spec", status: :parked, parked_reason: :needs_input, current_node: "spec")
      insert(:node_execution, run: run, node: "spec", outcome: :needs_input, duration_s: 190)
      card
    end

    test "one strip under the header, identical on Detail, Run, Talk and Activity (AC1)",
         %{conn: conn, board: board, code: code} do
      card = parked_on_spec(code, "Which scope should **board search** cover?")
      view = open_card(conn, board, card)

      for tab <- ~w(detail run talk activity) do
        view |> element("#card-drawer-tab-#{tab}") |> render_click()

        assert has_element?(view, "#card-drawer-tab-#{tab}[data-active='true']")
        assert has_element?(view, "#card-drawer-blocked-strip-eyebrow", "SPEC ASKED AND EXITED")
        assert has_element?(view, "#card-drawer-blocked-strip-question", "Which scope should board search cover?")
        refute has_element?(view, "#card-drawer-blocked-strip-question", "**")
        assert has_element?(view, "#card-drawer-blocked-strip-wait", "47m")
        assert has_element?(view, "#card-drawer-blocked-strip-wait-label", "waiting on you")
        assert has_element?(view, "#card-drawer-blocked-answer", "Answer")
      end

      # it is a direct child of the drawer panel, never inside a tab panel
      assert has_element?(view, "#card-drawer-panel > #card-drawer-blocked-strip")
      refute has_element?(view, "[id^='card-drawer-tab-panel-'] #card-drawer-blocked-strip")
    end

    test "a card set to needs_input by hand, with no run, reads NEEDS YOUR ANSWER (AC2)",
         %{conn: conn, board: board, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Manual block"})
      {:ok, card} = Cards.set_status(card, %{status: :needs_input})

      view = open_card(conn, board, card)

      assert has_element?(view, "#card-drawer-blocked-strip-eyebrow", "NEEDS YOUR ANSWER")
      refute has_element?(view, "#card-drawer-blocked-strip-question")
    end

    test "no strip for a card that is not blocked, or for an archived blocked card",
         %{conn: conn, board: board, code: code, user: user} do
      {:ok, calm} = Cards.create_card(code, %{title: "Calm"})
      refute has_element?(open_card(conn, board, calm), "#card-drawer-blocked-strip")

      {:ok, asked} = Cards.create_card(code, %{title: "Archived ask"})
      {:ok, asked} = Cards.request_input(asked, "Which bucket?")
      {:ok, archived} = Cards.archive_card(asked, {:user, user.id})

      view = open_card(conn, board, archived)
      assert has_element?(view, "#card-archived-banner")
      refute has_element?(view, "#card-drawer-blocked-strip")
    end

    test "a structured batch: the strip follows the stepper and counts N/M (AC4)",
         %{conn: conn, board: board, code: code} do
      questions = [
        %{"prompt" => "Which **timezone**?", "options" => ["Billing", "Viewer"], "allow_text" => true},
        %{"prompt" => "Any `size` limit?", "options" => ["None", "10 MB"], "allow_text" => true},
        %{"prompt" => "Archived cards too?", "options" => ["Yes", "No"], "allow_text" => false}
      ]

      {:ok, card} = Cards.create_card(code, %{title: "Batch"})
      {:ok, card} = Cards.request_input(card, questions, :agent)
      view = open_card(conn, board, card)

      assert has_element?(view, "#card-drawer-blocked-strip-question", "Which timezone?")
      refute has_element?(view, "#card-drawer-blocked-strip-question", "**")
      assert has_element?(view, "#card-drawer-blocked-strip-counter", "1/3")

      view |> element("#needs-input-option-0") |> render_click()

      assert has_element?(view, "#card-drawer-blocked-strip-question", "Any size limit?")
      refute has_element?(view, "#card-drawer-blocked-strip-question", "`")
      assert has_element?(view, "#card-drawer-blocked-strip-counter", "2/3")

      view |> element("#needs-input-back") |> render_click()
      assert has_element?(view, "#card-drawer-blocked-strip-counter", "1/3")
    end

    test "a single structured question shows no counter", %{conn: conn, board: board, code: code} do
      {:ok, card} = Cards.create_card(code, %{title: "Single"})
      {:ok, card} = Cards.request_input(card, [%{"prompt" => "Only one?"}], :agent)
      view = open_card(conn, board, card)

      assert has_element?(view, "#card-drawer-blocked-strip-question", "Only one?")
      refute has_element?(view, "#card-drawer-blocked-strip-counter")
    end

    test "Answer from the Run tab selects Detail and pushes focus-answer; again on Detail refocuses (AC5)",
         %{conn: conn, board: board, code: code} do
      card = parked_on_spec(code, "Which scope?")
      view = open_card(conn, board, card)

      # RE325 — a blocked card opens on Detail, so move to the Run tab first
      view |> element("#card-drawer-tab-run") |> render_click()
      assert has_element?(view, "#card-drawer-tab-panel-detail.hidden")

      view |> element("#card-drawer-blocked-answer") |> render_click()

      refute has_element?(view, "#card-drawer-tab-panel-detail.hidden")
      assert has_element?(view, "#card-drawer-tab-panel-run.hidden")
      assert has_element?(view, "#card-drawer-tab-detail[data-active='true']")
      assert has_element?(view, "#card-drawer-tab-panel-detail #needs-input-panel")
      assert_push_event(view, "focus-answer", %{})

      view |> element("#card-drawer-blocked-answer") |> render_click()

      refute has_element?(view, "#card-drawer-tab-panel-detail.hidden")
      assert_push_event(view, "focus-answer", %{})
    end

    test "Answer from the Talk tab leaves Talk for Detail", %{conn: conn, board: board, code: code} do
      card = parked_on_spec(code, "Which scope?")
      view = open_card(conn, board, card)

      view |> element("#card-drawer-tab-talk") |> render_click()
      view |> element("#card-drawer-blocked-answer") |> render_click()

      assert has_element?(view, "#card-drawer-tab-detail[data-active='true']")
      assert_push_event(view, "focus-answer", %{})
    end

    test "answer_jump is a no-op for a card that is not blocked", %{conn: conn, board: board, code: code} do
      {:ok, calm} = Cards.create_card(code, %{title: "Calm"})
      view = open_card(conn, board, calm)

      render_click(view, "answer_jump", %{})
      refute_push_event(view, "focus-answer", %{})
    end

    test "the strip is gone once the answer is submitted (AC6)", %{conn: conn, board: board, code: code} do
      {:ok, card} = Cards.create_card(code, %{title: "Clears"})
      {:ok, card} = Cards.request_input(card, "Which bucket?")
      view = open_card(conn, board, card)
      assert has_element?(view, "#card-drawer-blocked-strip")

      view |> form("#needs-input-form", answer: %{body: "relay-exports"}) |> render_submit()

      refute has_element?(view, "#card-drawer-blocked-strip")
      refute has_element?(open_card(conn, board, card), "#card-drawer-blocked-strip")
    end
  end

  describe "RE325 default drawer tab" do
    test "a blocked card with a parked run opens on Detail with the answer surface visible (AC1)",
         %{conn: conn, board: board, code: code} do
      card = parked_on_spec(code, "Which scope?")
      view = open_card(conn, board, card)

      assert has_element?(view, "#card-drawer-tab-detail[data-active='true']")
      refute has_element?(view, "#card-drawer-tab-panel-detail.hidden")
      assert has_element?(view, "#card-drawer-tab-panel-run.hidden")
      assert has_element?(view, "#card-drawer-tab-panel-detail #needs-input-panel")

      # opening does not steal focus (no keyboard pop on mobile) — only the Answer button focuses
      refute_push_event(view, "focus-answer", %{})
    end

    test "a card with a running run that is not blocked still opens on Run (AC3)",
         %{conn: conn, board: board, code: code} do
      {:ok, card} = Cards.create_card(code, %{title: "Mid flight"})
      {:ok, card} = Cards.assign_ai(card)
      {:ok, card} = Cards.set_status(card, %{status: :working})
      insert(:run, card: card, status: :running, current_node: "implement")

      view = open_card(conn, board, card)

      assert has_element?(view, "#card-drawer-tab-run[data-active='true']")
      assert has_element?(view, "#card-drawer-tab-panel-detail.hidden")
      refute has_element?(view, "#needs-input-panel")
    end

    test "an archived blocked card with a parked run keeps opening on Run — no answer surface renders",
         %{conn: conn, board: board, code: code, user: user} do
      card = parked_on_spec(code, "Which scope?")
      {:ok, archived} = Cards.archive_card(card, {:user, user.id})

      view = open_card(conn, board, archived)

      assert has_element?(view, "#card-archived-banner")
      assert has_element?(view, "#card-drawer-tab-run[data-active='true']")
      refute has_element?(view, "#needs-input-panel")
    end
  end
end
