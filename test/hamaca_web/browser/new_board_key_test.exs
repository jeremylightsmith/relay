defmodule HamacaWeb.Browser.NewBoardKeyTest do
  @moduledoc """
  Real-browser (Playwright) test for RE455's card key field in the New board picker. LiveView
  never patches a focused input's value, so the server's sanitized key can't reach the box while
  the user types in it — the `CardKeyInput` hook upper-cases and filters it client-side, before
  LiveView serializes the change. `Phoenix.LiveViewTest` runs no JS, so only a real browser
  proves it.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias PlaywrightEx.Frame

  @moduletag :playwright

  @key "#template-picker-key"

  # RE470: a boardless user's picker opens in first-run mode with the key prefilled, so the dev
  # user needs a board for the New board picker to open blank.
  setup do
    user = Accounts.ensure_dev_user!()
    _board = Boards.get_or_create_default_board(user)
    :ok
  end

  test "typing a1c into the card key leaves AC and previews its refs", %{conn: conn} do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/boards")
    |> assert_has("body .phx-connected")
    |> click("#top-bar-new-board")
    |> assert_has(@key)
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.type(frame_id, selector: @key, text: "a1c", timeout: 2_000)

      assert eventually_key(frame_id, &(&1 == "AC")) == "AC"
    end)
    |> assert_has("#template-picker-key-preview", text: "Cards will be AC1, AC2, AC3…")
  end

  # Polls the key input's value until `ok?` holds (or ~5s pass) and returns the last value seen,
  # so a failure prints what the box actually held.
  defp eventually_key(frame_id, ok?, tries \\ 50) do
    {:ok, value} =
      Frame.evaluate(frame_id, expression: "document.querySelector('#{@key}').value", timeout: 2_000)

    if ok?.(value) or tries == 0 do
      value
    else
      Process.sleep(100)
      eventually_key(frame_id, ok?, tries - 1)
    end
  end
end
