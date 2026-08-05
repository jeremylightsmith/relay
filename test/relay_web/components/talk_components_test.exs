defmodule RelayWeb.TalkComponentsTest do
  @moduledoc """
  RE268 — the pane is pinned to the `TALK: terminal session` block of
  `docs/designs/Relay Card Detail v5.dc.html` (lines ~261–339). Asserting the mockup's exact
  tokens is what makes "matches the artboard" a checked deliverable rather than a hope.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.TalkComponents

  defp event(attrs) do
    Map.merge(%{id: 1, seq: 1, kind: :out, text: "hello", dim: false}, attrs)
  end

  test "a user line uses the mockup's green chevron gutter" do
    html = render_component(&TalkComponents.talk_line/1, event: event(%{kind: :user, text: "why is this stuck?"}))

    assert html =~ "❯"
    assert html =~ "oklch(0.72 0.14 150)"
    assert html =~ "oklch(0.92 0.01 262)"
    assert html =~ "why is this stuck?"
  end

  test "a tool line is a dim middot line" do
    html =
      render_component(&TalkComponents.talk_line/1, event: event(%{kind: :tool, text: "Read · lib/relay.ex", dim: true}))

    assert html =~ "·"
    assert html =~ "oklch(0.5 0.02 262)"
    assert html =~ "oklch(0.56 0.03 262)"
  end

  test "an output line uses the bright body colour and a dim one the muted colour" do
    assert render_component(&TalkComponents.talk_line/1, event: event(%{})) =~ "oklch(0.86 0.015 262)"
    assert render_component(&TalkComponents.talk_line/1, event: event(%{dim: true})) =~ "oklch(0.58 0.03 262)"
  end

  test "every line is JetBrains Mono at 11.5px/19px" do
    html = render_component(&TalkComponents.talk_line/1, event: event(%{}))

    assert html =~ "JetBrains Mono"
    assert html =~ "font-size:11.5px"
    assert html =~ "line-height:19px"
  end

  test "the collapsed seed line reads `▸ seeded with REF · summary`" do
    html =
      render_component(&TalkComponents.talk_seed/1,
        ref: "DE3",
        summary: "3 fields · no plan yet · 2 runs",
        fields: [%{"label" => "description", "value" => "Search box"}],
        open?: false
      )

    assert html =~ "▸ seeded with DE3 · 3 fields · no plan yet · 2 runs"
    assert html =~ "oklch(0.62 0.09 150)"
    refute html =~ "Search box"
  end

  test "the expanded seed lists one padded label/value row per injected field" do
    html =
      render_component(&TalkComponents.talk_seed/1,
        ref: "DE3",
        summary: "3 fields",
        fields: [%{"label" => "description", "value" => "Search box"}, %{"label" => "plan", "value" => "not written"}],
        open?: true
      )

    assert html =~ "▾ seeded with DE3"
    assert html =~ "description  Search box"
    assert html =~ "plan         not written"
    assert html =~ "oklch(0.3 0.02 262)"
  end

  defp pane(assigns) do
    Map.merge(
      %{
        id: "talk-pane",
        ref: "DE3",
        title: "Board search",
        seed_summary: "3 fields",
        seed_fields: [],
        seed_open?: false,
        busy?: false,
        events: [event(%{})]
      },
      assigns
    )
  end

  test "the pane wears the mockup's dark shell, traffic lights and title" do
    html = render_component(&TalkComponents.talk_pane/1, pane(%{}))

    assert html =~ "oklch(0.185 0.015 262)"
    assert html =~ "oklch(0.62 0.15 25)"
    assert html =~ "oklch(0.75 0.13 85)"
    assert html =~ "oklch(0.7 0.14 145)"
    assert html =~ "relay talk DE3 — Board search"
    assert html =~ "scrollback kept · esc back to the card"
  end

  test "the state chip and the thinking indicator only appear while busy" do
    idle = render_component(&TalkComponents.talk_pane/1, pane(%{}))
    busy = render_component(&TalkComponents.talk_pane/1, pane(%{busy?: true}))

    assert idle =~ "card running"
    refute idle =~ "thinking…"
    assert busy =~ "working"
    assert busy =~ "✳"
    assert busy =~ "oklch(0.62 0.14 300)"
    assert busy =~ "thinking…"
  end

  test "the send control becomes Stop while a turn is in flight" do
    idle = render_component(&TalkComponents.talk_pane/1, pane(%{}))
    busy = render_component(&TalkComponents.talk_pane/1, pane(%{busy?: true}))

    refute idle =~ "talk_stop"
    assert busy =~ "talk_stop"
  end

  test "the slash-chip row is the mockup's five chips" do
    html = render_component(&TalkComponents.talk_pane/1, pane(%{}))

    for label <- ["why did review reject?", "fix it", "/card", "/run", "/clear"] do
      assert html =~ label
    end

    assert html =~ "oklch(0.22 0.018 262)"
  end

  test "the receipt line and copy-resume button belong to later steps and are absent" do
    html = render_component(&TalkComponents.talk_pane/1, pane(%{}))

    refute html =~ "copy resume cmd"
    refute html =~ "oklch(0.23 0.03 150)"
  end
end
