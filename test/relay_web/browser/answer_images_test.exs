defmodule RelayWeb.Browser.AnswerImagesTest do
  @moduledoc """
  Real-browser (Playwright) test for RE428's answer images. The server only pushes `image_link_*`
  events; the `.ImagePaste` colocated hook is what writes the `![name](…/attachments/<id>)` link
  into the stepper's answer text — JS `Phoenix.LiveViewTest` never runs, so only a real browser
  proves it. Phones are view-only: no 📎 below the `drawer:` breakpoint.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 1440, height: 900}]

  @text "#needs-input-text"
  @link ~r/^like this:\n!\[phone\.png\]\(https?:\/\/[^)]+\/attachments\/[0-9a-f-]{36}\)/

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Answer with a screenshot"})

    {:ok, card} =
      Cards.request_input(
        card,
        [
          %{"prompt" => "Which layout?", "options" => ["A", "B"]},
          %{"prompt" => "Where should the error show?", "options" => []}
        ],
        :agent
      )

    dir = Path.join(System.tmp_dir!(), "re428-answer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    phone = Path.join(dir, "phone.png")
    File.cp!(Application.app_dir(:relay, "priv/static/images/logo_light_128.png"), phone)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{board: board, ref: Cards.ref(board, card), phone: phone}
  end

  defp open_step_2(conn, ctx) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{ctx.board.slug}?card=#{ctx.ref}")
    |> assert_has("body .phx-connected")
    |> click("#needs-input-option-0")
    |> assert_has("#needs-input-progress", text: "Question 2 of 2")
  end

  test "an image attached on step 2 becomes a link in the answer text", ctx do
    ctx.conn
    |> open_step_2(ctx)
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.type(frame_id, selector: @text, text: "like this:", timeout: 2_000)

      {:ok, _} =
        Frame.set_input_files(frame_id,
          selector: "#needs-input-images-attach input[type=file]",
          local_paths: [ctx.phone],
          timeout: 2_000
        )

      assert eventually_value(frame_id, &(&1 =~ @link)) =~ @link
    end)
  end

  @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
  test "a phone has no 📎", ctx do
    ctx.conn
    |> open_step_2(ctx)
    |> unwrap(fn %{frame_id: frame_id} ->
      assert {:ok, true} = Frame.is_visible(frame_id, selector: @text, timeout: 2_000)
      assert {:ok, false} = Frame.is_visible(frame_id, selector: "#needs-input-images-attach", timeout: 2_000)
    end)
  end

  # Polls the answer text until `ok?` holds (or ~5s pass) and returns the last value seen, so a
  # failure prints what the textarea actually held.
  defp eventually_value(frame_id, ok?, tries \\ 50) do
    {:ok, value} = Frame.input_value(frame_id, selector: @text, timeout: 2_000)

    if ok?.(value) or tries == 0 do
      value
    else
      Process.sleep(100)
      eventually_value(frame_id, ok?, tries - 1)
    end
  end
end
