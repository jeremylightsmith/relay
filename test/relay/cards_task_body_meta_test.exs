defmodule Relay.CardsTaskBodyMetaTest do
  use ExUnit.Case, async: true

  alias Relay.Cards

  # Built rather than typed so a literal triple-backtick never has to appear in this source.
  @fence String.duplicate("`", 3)

  describe "task_body_meta/1 (RE356)" do
    test "nil and blank bodies have no meta — there is nothing to open" do
      assert Cards.task_body_meta(nil) == nil
      assert Cards.task_body_meta("") == nil
      assert Cards.task_body_meta("  \n\t \n") == nil
    end

    test "plain text counts its lines, ignoring the trailing newline" do
      assert Cards.task_body_meta("one\ntwo\nthree\n") == %{lines: 3, code_blocks: 0}
      assert Cards.task_body_meta("just one") == %{lines: 1, code_blocks: 0}
    end

    test "CRLF line endings count the same as LF" do
      assert Cards.task_body_meta("one\r\ntwo\r\n") == %{lines: 2, code_blocks: 0}
    end

    test "one fenced block counts once per open/close pair" do
      body = "Intro.\n\n#{@fence}elixir\nx = 1\n#{@fence}\n"
      assert Cards.task_body_meta(body) == %{lines: 5, code_blocks: 1}
    end

    test "two fenced blocks count two" do
      body = "#{@fence}elixir\nx = 1\n#{@fence}\n\n#{@fence}\ny = 2\n#{@fence}"
      assert Cards.task_body_meta(body) == %{lines: 7, code_blocks: 2}
    end

    test "an unclosed fence rounds down, and a mid-line fence is not a fence" do
      assert Cards.task_body_meta("#{@fence}elixir\nx = 1") == %{lines: 2, code_blocks: 0}
      assert Cards.task_body_meta("use #{@fence} inline") == %{lines: 1, code_blocks: 0}
    end
  end
end
