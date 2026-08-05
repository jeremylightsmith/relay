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

  # RE268 quality review — `talk_seed/1`'s toggle button carried a hardcoded id, so a page
  # rendering more than one `talk_pane` (the storybook page renders four) emitted duplicate DOM
  # ids. Defaults to the old literal for standalone (test/story) use, but `talk_pane` overrides
  # it the same way `-transcript` is already derived from `@id`.
  test "the seed toggle defaults its id but accepts an override" do
    default = render_component(&TalkComponents.talk_seed/1, ref: "DE3", open?: false)
    assert default =~ ~s(id="talk-seed-toggle")

    overridden =
      render_component(&TalkComponents.talk_seed/1, ref: "DE3", open?: false, id: "talk-pane-seed-toggle")

    assert overridden =~ ~s(id="talk-pane-seed-toggle")
    refute overridden =~ ~s(id="talk-seed-toggle")
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
    # The artboard's gutter is `k.padEnd(12) + v` — the label column is 12 wide, not 13.
    assert html =~ ">description Search box<"
    assert html =~ ">plan        not written<"
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

  # RE268 quality review — the artboard sets `font-size:11px` on the title bar and `10.5px` on
  # the footer copy and slash chips with NO line-height override, so each inherits the
  # surrounding normal line-height. Concatenating `mono()` (11.5px/19px) and only overriding
  # font-size left a stray `line-height:19px` on all three — never visible as a rendering bug at
  # this line-height, but a real drift from the pinned artboard values.
  test "the title bar, footer copy and slash chips carry no stray 19px line-height" do
    html = render_component(&TalkComponents.talk_pane/1, pane(%{}))

    [title_tag] = Regex.run(~r/<span[^>]*>\s*relay talk DE3/, html)
    assert title_tag =~ "font-size:11px"
    refute title_tag =~ "line-height:19px"

    [footer_tag] = Regex.run(~r/<span[^>]*>\s*scrollback kept/, html)
    assert footer_tag =~ "font-size:10.5px"
    refute footer_tag =~ "line-height:19px"

    [chip_tag] = Regex.run(~r/<button[^>]*>\s*fix it/, html)
    assert chip_tag =~ "font-size:10.5px"
    refute chip_tag =~ "line-height:19px"
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

  # RE268 quality review — `v5pulse` is an artboard-only keyframe (never shipped to
  # assets/css/app.css), so the busy indicator rendered static. The app already ships the
  # identical keyframe as `relaypulse` (assets/css/app.css:666, mirrored into storybook.css) and
  # uses it a few hundred lines away in this same drawer (core_components.ex health chip).
  test "the thinking indicator pulses with the app's shared keyframe, not the artboard's" do
    busy = render_component(&TalkComponents.talk_pane/1, pane(%{busy?: true}))

    assert busy =~ "animation:relaypulse 1.2s ease-in-out infinite"
    refute busy =~ "v5pulse"
  end

  # RE268 whole-branch review — Stop must render *instead of* the composer, not beside it. While
  # the composer stayed live, Enter on a second message hit `{:error, :turn_in_flight}`, which
  # the LiveView swallows: no flash, no notice, the text left sitting in the box. Removing the
  # node is also what clears it — LiveView never resets an uncontrolled text input on submit.
  test "the send control becomes Stop while a turn is in flight" do
    idle = render_component(&TalkComponents.talk_pane/1, pane(%{}))
    busy = render_component(&TalkComponents.talk_pane/1, pane(%{busy?: true}))

    refute idle =~ "talk_stop"
    assert busy =~ "talk_stop"

    assert idle =~ "talk_send"
    refute busy =~ "talk_send"
    refute busy =~ ~s(id="talk-pane-composer")
  end

  # RE268 quality review — `talk-composer`, `talk-stop` and `talk-seed-toggle` were hardcoded,
  # even though `talk_pane/1` takes an `id` and already derives `-transcript` from it. The
  # storybook page renders four `talk_pane` variations on one page with distinct `id`s
  # specifically to catch this: without deriving, each of those three ids would repeat 3-4 times.
  test "the composer, stop button and seed toggle derive their ids from the pane's id" do
    idle = render_component(&TalkComponents.talk_pane/1, pane(%{id: "talk-pane-2"}))
    busy = render_component(&TalkComponents.talk_pane/1, pane(%{id: "talk-pane-2", busy?: true}))

    assert idle =~ ~s(id="talk-pane-2-composer")
    assert idle =~ ~s(id="talk-pane-2-seed-toggle")
    assert busy =~ ~s(id="talk-pane-2-seed-toggle")
    assert busy =~ ~s(id="talk-pane-2-stop")
  end

  test "the slash-chip row is the mockup's five chips" do
    html = render_component(&TalkComponents.talk_pane/1, pane(%{}))

    for label <- ["why did review reject?", "fix it", "/card", "/run", "/clear"] do
      assert html =~ label
    end

    assert html =~ "oklch(0.22 0.018 262)"
  end

  test "the prompt chips are hidden while a turn is live, but /clear stays" do
    # Four of the five post a turn, which Talk refuses with {:error, :turn_in_flight} and the
    # LiveView renders nothing for — a live-looking control that silently does nothing, which is
    # the exact thing removing the composer while busy exists to prevent.
    busy = render_component(&TalkComponents.talk_pane/1, pane(%{busy?: true}))

    for label <- ["why did review reject?", "fix it", "/card", "/run"] do
      refute busy =~ label
    end

    assert busy =~ TalkComponents.slash_clear()
  end

  test "the receipt line and copy-resume button belong to later steps and are absent" do
    html = render_component(&TalkComponents.talk_pane/1, pane(%{}))

    refute html =~ "copy resume cmd"
    refute html =~ "oklch(0.23 0.03 150)"
  end
end
