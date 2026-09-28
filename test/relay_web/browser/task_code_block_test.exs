defmodule RelayWeb.Browser.TaskCodeBlockTest do
  @moduledoc """
  RE356 — real-browser proof of the `CodeBlockCopy` hook: opening a task whose body has a fenced
  block decorates it with the language label, line count and `copy` button. The strip is built
  client-side, so a LiveView test cannot see it.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  @moduletag :playwright

  @fence String.duplicate("`", 3)

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    {:ok, card} = Cards.create_card(code, %{title: "Code block strip"})

    {:ok, [task]} =
      Cards.add_tasks(card, [%{title: "With code", body: "Intro.\n\n#{@fence}elixir\nx = 1\ny = 2\n#{@fence}\n"}])

    %{board: board, card: card, task: task}
  end

  test "an open task body's code block gets a language, line-count and copy strip", ctx do
    body = "#sub-task-#{ctx.task.id}-body"

    ctx.conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{ctx.board.slug}?card=#{ctx.board.key}#{ctx.card.ref_number}")
    |> assert_has("#card-drawer-panel")
    |> assert_has("body .phx-connected")
    |> click("#sub-task-#{ctx.task.id}-toggle")
    |> assert_has("#{body} .code-block-strip .code-block-lang", text: "elixir")
    |> assert_has("#{body} .code-block-strip .code-block-lines", text: "2 lines")
    |> assert_has("#{body} .code-block-strip button.code-block-copy", text: "copy")
  end
end
