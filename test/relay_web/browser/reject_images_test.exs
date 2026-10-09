defmodule RelayWeb.Browser.RejectImagesTest do
  @moduledoc """
  Real-browser (Playwright) test for RE428. The server only pushes `image_link_*` events; the
  `.ImagePaste` colocated hook is what writes and removes the `![name](…/attachments/<id>)` link
  in the reject note — JS `Phoenix.LiveViewTest` never runs, so only a real browser proves it.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 1440, height: 900}]

  @note "#review-request-note"
  @link ~r/^too tall:\n!\[shot\.png\]\(https?:\/\/[^)]+\/attachments\/[0-9a-f-]{36}\)/

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, card} = Cards.create_card(review, %{title: "Reject with a screenshot"})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})

    dir = Path.join(System.tmp_dir!(), "re428-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    shot = Path.join(dir, "shot.png")
    File.cp!(Application.app_dir(:relay, "priv/static/images/logo_light_128.png"), shot)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{board: board, ref: Cards.ref(board, card), shot: shot}
  end

  test "an attached image becomes a link in the note, and its ✕ takes the link out again", ctx do
    ctx.conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{ctx.board.slug}?card=#{ctx.ref}")
    |> assert_has("body .phx-connected")
    |> click("#review-request-changes")
    |> assert_has(@note)
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.type(frame_id, selector: @note, text: "too tall:", timeout: 2_000)

      {:ok, _} =
        Frame.set_input_files(frame_id,
          selector: "#review-reject-images-attach input[type=file]",
          local_paths: [ctx.shot],
          timeout: 2_000
        )

      assert eventually_value(frame_id, &(&1 =~ @link)) =~ @link
    end)
    |> click("#review-reject-images-pending button[title=Remove]")
    |> unwrap(fn %{frame_id: frame_id} ->
      assert eventually_value(frame_id, &(&1 == "too tall:")) == "too tall:"
    end)
  end

  # Polls the note's value until `ok?` holds (or ~5s pass) and returns the last value seen, so a
  # failure prints what the textarea actually held.
  defp eventually_value(frame_id, ok?, tries \\ 50) do
    {:ok, value} = Frame.input_value(frame_id, selector: @note, timeout: 2_000)

    if ok?.(value) or tries == 0 do
      value
    else
      Process.sleep(100)
      eventually_value(frame_id, ok?, tries - 1)
    end
  end
end
