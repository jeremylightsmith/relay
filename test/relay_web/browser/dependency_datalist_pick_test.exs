defmodule RelayWeb.Browser.DependencyDatalistPickTest do
  @moduledoc """
  Real-browser (Playwright) tests for RE363. The drawer's Blocked by input is a plain
  `<input list=…>` backed by a native `<datalist>`; it used to persist only on Enter, so picking a
  suggestion just filled the box and looked saved when it wasn't. The `SubmitOnDatalistPick` hook
  now submits the form when an `input` event is a suggestion PICK (not a keystroke) whose value is
  one of the datalist's options.

  `Phoenix.LiveViewTest` never runs JS hooks, so only a real browser can prove it — same reasoning
  as `RelayWeb.Browser.TypingKeyGuardTest`. A browser's native datalist popup can't be clicked
  through Playwright, so a pick is simulated the way each engine reports one: an `InputEvent` with
  `inputType: "insertReplacementText"` (Chromium / Firefox) and a bare `Event("input")` (WebKit).
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  @input "#card-drawer-dependency-input"

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))

    %{board: board, code: code}
  end

  test "picking a suggestion adds the blocker without Enter and empties the input", ctx do
    [first, second] = create_cards(ctx.code, ctx.board, ["Blocker one", "Blocker two"])
    [dependent] = create_cards(ctx.code, ctx.board, ["Dependent"])

    ctx.conn
    |> open_drawer(ctx.board, dependent)
    |> pick(first, :insert_replacement_text)
    |> assert_has("#card-drawer-blocked-by-#{first}")
    |> assert_input_empty()
    # WebKit reports a datalist pick as a bare Event with no inputType.
    |> pick(second, :bare_event)
    |> assert_has("#card-drawer-blocked-by-#{second}")
    |> assert_has("#card-drawer-blocked-by-#{first}")
    |> assert_input_empty()
  end

  test "typing a ref key by key never submits on a prefix; Enter adds exactly that ref", ctx do
    # A fresh default board numbers these 1..12, so RE1 is a prefix of RE10/RE11/RE12. The
    # dependent is created last so it is neither half of the pair.
    blockers = create_cards(ctx.code, ctx.board, Enum.map(1..12, &"Blocker #{&1}"))
    [dependent] = create_cards(ctx.code, ctx.board, ["Dependent"])

    {short, long} = prefix_pair(blockers)

    ctx.conn
    |> open_drawer(ctx.board, dependent)
    |> unwrap(fn %{frame_id: frame_id} ->
      # Frame.type sends real keystrokes (inputType "insertText"). On the way to `long` the value
      # passes through `short`, which IS a datalist option — a hook that keyed on the value alone
      # would submit `short` right there.
      {:ok, _} = Frame.type(frame_id, selector: @input, text: long, timeout: 2_000)
    end)
    |> refute_has("#card-drawer-blocked-by .dependency-chip")
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.press(frame_id, selector: @input, key: "Enter", timeout: 2_000)
    end)
    |> assert_has("#card-drawer-blocked-by-#{long}")
    # The channel is ordered: had a mid-typing submit of `short` happened, its chip would be
    # rendered by the time Enter's `long` chip is.
    |> refute_has("#card-drawer-blocked-by-#{short}")
    |> assert_input_empty()
  end

  test "a refused pick (a cycle) adds nothing and shows the inline error", ctx do
    {:ok, card_a} = Cards.create_card(ctx.code, %{title: "Card A"})
    {:ok, card_b} = Cards.create_card(ctx.code, %{title: "Card B"})
    a = Cards.ref(ctx.board, card_a)
    b = Cards.ref(ctx.board, card_b)
    # A is blocked by B, so B blocked by A would close a cycle.
    {:ok, _} = Cards.set_dependencies(ctx.board, card_a, [b])

    ctx.conn
    |> open_drawer(ctx.board, b)
    |> pick(a, :insert_replacement_text)
    |> assert_has("#card-drawer-dependency-error", text: "dependency cycle")
    |> refute_has("#card-drawer-blocked-by-#{a}")
  end

  # Creates one card per title in `stage` and returns their refs, in creation order.
  defp create_cards(stage, board, titles) do
    Enum.map(titles, fn title ->
      {:ok, card} = Cards.create_card(stage, %{title: title})
      Cards.ref(board, card)
    end)
  end

  defp prefix_pair(refs) do
    pair =
      Enum.find_value(refs, fn short ->
        long = Enum.find(refs, &(&1 != short and String.starts_with?(&1, short)))
        long && {short, long}
      end)

    assert pair, "precondition: expected two refs where one prefixes the other, got #{inspect(refs)}"
    pair
  end

  defp open_drawer(conn, board, ref) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}?card=#{ref}")
    # Wait for THIS page's socket, then for the async-loaded drawer body: the input only exists
    # once connected, so its hook is mounted by the time we act on it.
    |> assert_has("body .phx-connected")
    |> assert_has(@input)
  end

  # Simulates a native datalist pick: focus the input (as a real click on the popup leaves it),
  # set the value, and fire the `input` event the given engine would fire for a pick.
  defp pick(session, ref, kind) do
    event =
      case kind do
        :insert_replacement_text ->
          ~s|new InputEvent("input", {bubbles: true, inputType: "insertReplacementText"})|

        :bare_event ->
          ~s|new Event("input", {bubbles: true})|
      end

    expression = """
    (() => {
      const el = document.querySelector(#{Jason.encode!(@input)});
      el.focus();
      el.value = #{Jason.encode!(ref)};
      el.dispatchEvent(#{event});
    })()
    """

    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
    end)
  end

  # The server clears @dependency_input on success; wait for the patch, then read the value back
  # as the load-bearing assertion.
  defp assert_input_empty(session) do
    unwrap(session, fn %{frame_id: frame_id} ->
      _ =
        Frame.wait_for_function(frame_id,
          expression: "document.querySelector(#{Jason.encode!(@input)}).value === ''",
          timeout: 5_000
        )

      {:ok, value} = Frame.input_value(frame_id, selector: @input, timeout: 2_000)
      assert value == "", "the Blocked by input still holds #{inspect(value)} after the add"
    end)
  end
end
