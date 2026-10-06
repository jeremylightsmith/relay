defmodule RelayWeb.Browser.ActionPendingTest do
  @moduledoc """
  Real-browser (Playwright) test for RE394 · card mockup "A — the pressed button spins and says
  what it's doing": a server-bound action shows its pressed face in the click's own frame — a
  spinner and a verb-ing label, the same width, darkened — while its group's other controls go
  inert, and the server's reply clears it with today's toast/panel behaviour.

  The face is pure CSS keyed on LiveView's client-side `phx-click-loading` /
  `phx-submit-loading` classes, so only a real browser can see it. `liveSocket.enableLatencySim/1`
  holds the reply back long enough to read the pressed state; it persists in `sessionStorage`,
  so every test turns it off again once the reply has landed.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo
  alias Schemas.Stage

  @moduletag :playwright

  @latency_ms 1_500
  @reply_timeout 6_000

  setup do
    user = Accounts.ensure_dev_user!()
    %{board: Boards.get_or_create_default_board(user)}
  end

  test "Approve presses in place: spinner, Approving…, same width, Request changes inert", %{
    conn: conn,
    board: board
  } do
    card = spec_review_card(board, "Pressed approve")
    next_ref = board |> spec_review_card("Next in review") |> then(&Cards.ref(board, &1))

    conn
    |> open_drawer(board, card, "#review-approve")
    |> latency_on()
    |> unwrap(fn %{frame_id: frame_id} ->
      width = width(frame_id, "#review-approve")
      {:ok, _} = Frame.click(frame_id, selector: "#review-approve", timeout: 2_000)

      approve = probe(frame_id, "#review-approve")
      assert "phx-click-loading" in approve["classes"]
      assert approve["filter"] == "brightness(0.85)"
      assert_in_delta approve["width"], width, 0.5

      face = probe(frame_id, "#review-approve .pending-face")
      assert face["visibility"] == "visible"
      assert face["text"] == "Approving…"
      assert probe(frame_id, "#review-approve .pending-idle")["visibility"] == "hidden"

      assert_inert(frame_id, "#review-request-changes")
    end)
    |> assert_after_decision("Approved #{Cards.ref(board, card)}", next_ref)
  end

  test "Reject → X presses in place: Sending back…, same width, not disabled-grey, note + Cancel inert", %{
    conn: conn,
    board: board
  } do
    card = spec_review_card(board, "Pressed reject")
    next_ref = board |> spec_review_card("Next in review") |> then(&Cards.ref(board, &1))

    conn
    |> open_drawer(board, card, "#review-request-changes")
    |> latency_on()
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.click(frame_id, selector: "#review-request-changes", timeout: 2_000)
    end)
    |> assert_has("#review-send-back", timeout: @reply_timeout)
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.type(frame_id, selector: "#review-request-note", text: "Header spacing is off", timeout: 2_000)

      width = width(frame_id, "#review-send-back")
      background = probe(frame_id, "#review-send-back")["background"]
      {:ok, _} = Frame.click(frame_id, selector: "#review-send-back", timeout: 2_000)

      send_back = probe(frame_id, "#review-send-back")
      assert "phx-submit-loading" in send_back["classes"]
      assert_in_delta send_back["width"], width, 0.5
      # LiveView disables the submitting form's buttons; daisyUI's :disabled grey must not win.
      assert send_back["background"] == background

      face = probe(frame_id, "#review-send-back .pending-face")
      assert face["visibility"] == "visible"
      assert face["text"] == "Sending back…"

      assert_inert(frame_id, "#review-request-note")
      assert_inert(frame_id, "#review-cancel-reject")
    end)
    |> assert_after_decision("Sent #{Cards.ref(board, card)} back", next_ref)
  end

  test "needs-input Send presses in place with Sending…", %{conn: conn, board: board} do
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Pressed send"})
    {:ok, card} = Cards.request_input(card, "Which header?", :agent)

    conn
    |> open_drawer(board, card, "#needs-input-send")
    |> latency_on()
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.type(frame_id, selector: "#needs-input-answer", text: "Use the board header", timeout: 2_000)
      {:ok, _} = Frame.click(frame_id, selector: "#needs-input-send", timeout: 2_000)

      face = probe(frame_id, "#needs-input-send .pending-face")
      assert face["visibility"] == "visible"
      assert face["text"] == "Sending…"
    end)
    |> refute_has("#needs-input-panel", timeout: @reply_timeout)
    |> latency_off()
  end

  test "a Move-to row presses in place with Moving…; the other rows go inert", %{conn: conn, board: board} do
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    other = Enum.find(board.stages, &(&1.name == "Plan"))
    {:ok, card} = Cards.create_card(backlog, %{title: "Pressed move"})

    conn
    |> open_drawer(board, card, "#card-drawer-stage-chip")
    |> latency_on()
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.click(frame_id, selector: "#card-drawer-stage-chip", timeout: 2_000)
    end)
    |> assert_has("#card-drawer-move-to-#{spec.id}", timeout: @reply_timeout)
    |> unwrap(fn %{frame_id: frame_id} ->
      row = "#card-drawer-move-to-#{spec.id}"
      {:ok, _} = Frame.click(frame_id, selector: row, timeout: 2_000)

      face = probe(frame_id, "#{row} .pending-face")
      assert face["visibility"] == "visible"
      assert face["text"] == "Moving…"
      assert probe(frame_id, row)["text"] =~ "Spec"

      assert_inert(frame_id, "#card-drawer-move-to-#{other.id}")
    end)
    |> assert_has("#card-drawer-stage-chip", text: "Spec", timeout: @reply_timeout)
    |> latency_off()
  end

  # The reply lands with today's behaviour: the decision toast fires only when another card still
  # awaits review in the lane (BoardLive.after_review_decision/5 — a lone card closes the drawer
  # silently), so each gate test seeds a second card. The decided card's panel is gone — the drawer
  # has moved on to that next card — and the next card's buttons are back on their idle face.
  defp assert_after_decision(session, toast, next_ref) do
    session
    |> assert_has("#flash-info", text: toast, timeout: @reply_timeout)
    |> assert_has(".drawer-card-ref", text: next_ref, timeout: @reply_timeout)
    |> unwrap(fn %{frame_id: frame_id} ->
      refute "phx-click-loading" in probe(frame_id, "#review-approve")["classes"]
      assert probe(frame_id, "#review-approve .pending-face")["visibility"] == "hidden"
    end)
    |> latency_off()
  end

  # A card in the default board's Spec:Review sub-lane, waiting at the review gate.
  defp spec_review_card(board, title) do
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Repo.get_by!(Stage, board_id: board.id, parent_id: spec.id, type: :review)
    {:ok, card} = Cards.create_card(review, %{title: title})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    card
  end

  defp open_drawer(conn, board, card, ready_selector) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{board.key}#{card.ref_number}")
    |> assert_has(ready_selector)
    |> assert_has("body .phx-connected")
  end

  defp latency_on(session) do
    unwrap(session, fn %{frame_id: frame_id} ->
      eval!(frame_id, "(window.liveSocket.enableLatencySim(#{@latency_ms}), true)")
    end)
  end

  defp latency_off(session) do
    unwrap(session, fn %{frame_id: frame_id} ->
      eval!(frame_id, "(window.liveSocket.disableLatencySim(), true)")
    end)
  end

  defp eval!(frame_id, js) do
    {:ok, value} = Frame.evaluate(frame_id, expression: "(() => #{js})()", timeout: 2_000)
    value
  end

  defp width(frame_id, selector), do: probe(frame_id, selector)["width"]

  # The element's classes, rendered width, rendered text and the computed styles the pressed face
  # and the inert group change.
  defp probe(frame_id, selector) do
    frame_id
    |> eval!("""
    (() => {
      const el = document.querySelector(#{Jason.encode!(selector)});
      if (!el) return JSON.stringify(null);
      const cs = getComputedStyle(el);
      return JSON.stringify({
        classes: [...el.classList],
        width: el.getBoundingClientRect().width,
        text: el.innerText.trim(),
        visibility: cs.visibility,
        filter: cs.filter,
        background: cs.backgroundColor,
        opacity: cs.opacity,
        pointerEvents: cs.pointerEvents
      });
    })()
    """)
    |> Jason.decode!()
    |> tap(&assert(&1, "#{selector} is not on the page"))
  end

  defp assert_inert(frame_id, selector) do
    sibling = probe(frame_id, selector)
    assert sibling["opacity"] == "0.4", "#{selector} opacity is #{sibling["opacity"]}"
    assert sibling["pointerEvents"] == "none", "#{selector} pointer-events is #{sibling["pointerEvents"]}"
  end
end
