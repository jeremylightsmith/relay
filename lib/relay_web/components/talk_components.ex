defmodule RelayWeb.TalkComponents do
  @moduledoc """
  The Talk pane (RE268 / ADR 0009) — the card drawer's terminal session, matching the
  `TALK: terminal session` block of `docs/designs/Relay Card Detail v5.dc.html` (lines ~261–339).

  Deliberately NOT in `core_components.ex`, which is already ~3.2k lines, and self-contained (no
  CoreComponents import) so CoreComponents can render it without a compile cycle — the same rule
  `RelayWeb.RunComponents` follows.

  The `oklch(...)` values here are the artboard's, spelled out inline rather than themed: this
  pane is a terminal, so it is dark in BOTH daisyUI themes and must not drift with them. Its
  colours are pinned by `talk_components_test.exs`.

  The `✓` receipt (`:act`) line and `copy resume cmd` are drawn in the artboard but belong to
  step 2 ([AC16]) and are deliberately not built here.
  """
  use Phoenix.Component

  attr :event, :map, required: true, doc: "a %Schemas.TalkEvent{} (or a plain map in stories/tests)"

  def talk_line(assigns) do
    ~H"""
    <div :if={@event.kind == :user} style="display:flex;gap:8px;padding-top:9px;">
      <span style={mono() <> "color:oklch(0.72 0.14 150);flex:0 0 auto;"}>❯</span>
      <span style={mono() <> "color:oklch(0.92 0.01 262);flex:1;min-width:0;"}>{@event.text}</span>
    </div>
    <div :if={@event.kind == :tool} style="display:flex;gap:8px;">
      <span style={mono() <> "color:oklch(0.5 0.02 262);flex:0 0 auto;"}>·</span>
      <span style={mono() <> "color:oklch(0.56 0.03 262);flex:1;min-width:0;"}>{@event.text}</span>
    </div>
    <span
      :if={@event.kind in [:out, :error]}
      style={mono() <> "color:" <> out_color(@event) <> ";padding-bottom:2px;display:block;"}
    >
      {@event.text}
    </span>
    """
  end

  attr :id, :string,
    default: "talk-seed-toggle",
    doc: "the toggle button's id — `talk_pane/1` derives it from its own `@id`, the way `-transcript` already is"

  attr :ref, :string, required: true
  attr :summary, :string, default: ""
  attr :fields, :list, default: []
  attr :open?, :boolean, default: false

  def talk_seed(assigns) do
    ~H"""
    <div style="display:flex;flex-direction:column;gap:1px;padding-bottom:8px;">
      <span style={mono() <> "color:oklch(0.52 0.02 262);"}>relay talk {@ref}</span>
      <button
        type="button"
        id={@id}
        phx-click="talk_toggle_seed"
        style={"text-align:left;background:transparent;border:none;padding:0;" <> mono() <> "color:oklch(0.62 0.09 150);"}
      >
        {if @open?, do: "▾", else: "▸"} seeded with {@ref} · {@summary}
      </button>
      <div
        :if={@open?}
        style="display:flex;flex-direction:column;gap:2px;padding:6px 0 4px 14px;border-left:1px solid oklch(0.3 0.02 262);margin-left:2px;"
      >
        <%!-- The gutter is the artboard's `k.padEnd(12) + v` — exactly 12 columns, so the row is
        one interpolation: two with a literal space between them silently make it 13. `phx-no-format`
        is load-bearing for the same reason `white-space:pre-wrap` is — the HEEx formatter would
        break the tag over three lines, and every preserved newline and indent then renders as a
        blank line and a 6-space indent the artboard does not draw. --%>
        <span
          :for={field <- @fields}
          phx-no-format
          style={mono() <> "font-size:11px;line-height:18px;color:oklch(0.6 0.025 262);white-space:pre-wrap;"}
        >{String.pad_trailing(field["label"], 12) <> field["value"]}</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :ref, :string, required: true
  attr :title, :string, required: true
  attr :seed_summary, :string, default: ""
  attr :seed_fields, :list, default: []
  attr :seed_open?, :boolean, default: false
  attr :busy?, :boolean, default: false

  attr :awaiting?, :boolean,
    default: false,
    doc: "the card is parked on a question — switches the lead prompt, per artboard line 829"

  attr :events, :list, default: nil, doc: "a plain list (stories/tests); nil when `stream` is used"
  attr :stream, :any, default: nil, doc: "the LiveView @streams.talk_events assign"

  def talk_pane(assigns) do
    assigns = assign(assigns, :items, transcript_items(assigns))

    ~H"""
    <div
      id={@id}
      style="height:548px;background:oklch(0.185 0.015 262);display:flex;flex-direction:column;"
    >
      <div style="flex:0 0 auto;display:flex;align-items:center;gap:9px;padding:10px 16px;border-bottom:1px solid oklch(0.26 0.018 262);">
        <span style="display:flex;gap:5px;flex:0 0 auto;">
          <span style="width:9px;height:9px;border-radius:50%;background:oklch(0.62 0.15 25);"></span>
          <span style="width:9px;height:9px;border-radius:50%;background:oklch(0.75 0.13 85);"></span>
          <span style="width:9px;height:9px;border-radius:50%;background:oklch(0.7 0.14 145);"></span>
        </span>
        <span style={mono_family() <> "font-size:11px;color:oklch(0.66 0.02 262);flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;"}>
          relay talk {@ref} — {@title}
        </span>
        <span style={chip_style(@busy?)}>{if @busy?, do: "working", else: "card running"}</span>
        <button
          type="button"
          phx-click="drawer_tab"
          phx-value-tab="detail"
          style={mono_family() <> "flex:0 0 auto;font-size:10px;font-weight:600;background:transparent;border:none;padding:0;color:oklch(0.6 0.02 262);"}
        >
          esc
        </button>
      </div>

      <div style="flex:1;min-height:0;overflow-y:auto;padding:15px 16px;display:flex;flex-direction:column;gap:2px;">
        <.talk_seed
          id={"#{@id}-seed-toggle"}
          ref={@ref}
          summary={@seed_summary}
          fields={@seed_fields}
          open?={@seed_open?}
        />

        <div id={"#{@id}-transcript"} phx-update={@stream && "stream"}>
          <div :for={{dom_id, event} <- @items} id={dom_id}>
            <.talk_line event={event} />
          </div>
        </div>

        <div :if={@busy?} style="display:flex;gap:8px;padding-top:4px;">
          <span style={mono() <> "color:oklch(0.62 0.14 300);"}>✳</span>
          <span style={mono() <> "color:oklch(0.58 0.03 262);animation:relaypulse 1.2s ease-in-out infinite;"}>
            thinking…
          </span>
        </div>

        <%!--
          RE268 whole-branch review — the composer is REMOVED while a turn is live, not merely
          decorated: Stop in the footer renders in its place (`plan.md`: "talk_stop renders
          instead of the composer's submit affordance while @busy?"). Two reasons it must be
          removal rather than `disabled`:

            * a second Enter is refused server-side (`{:error, :turn_in_flight}`) with no flash
              and no inline notice, so a live composer is a silent dead end; and
            * removal is the only thing that clears the box. LiveView does not reset an
              uncontrolled text input on `phx-submit` — it flags it `PHX_HAS_SUBMITTED`, and the
              patcher never syncs a text input's value from attributes, so every message after
              the first would be typed on top of the previous one. A fresh node has an empty
              value.
        --%>
        <form
          :if={!@busy?}
          id={"#{@id}-composer"}
          phx-submit="talk_send"
          style="display:flex;gap:8px;padding-top:9px;align-items:baseline;"
        >
          <span style={mono() <> "color:oklch(0.72 0.14 150);flex:0 0 auto;"}>❯</span>
          <input
            type="text"
            name="text"
            placeholder={lead_prompt(@awaiting?)}
            autocomplete="off"
            style={mono() <> "flex:1;min-width:0;border:none;outline:none;background:transparent;color:oklch(0.94 0.01 262);caret-color:oklch(0.72 0.14 150);"}
          />
        </form>
      </div>

      <div style="flex:0 0 auto;border-top:1px solid oklch(0.26 0.018 262);padding:9px 16px 11px 16px;display:flex;flex-direction:column;gap:7px;">
        <div style="display:flex;gap:6px;flex-wrap:wrap;">
          <%!-- Gated on !@busy? for the same reason the composer is removed while busy (above):
                four of these five route through talk_slash -> Talk.post_message/3, which answers
                {:error, :turn_in_flight} and renders nothing. A live-looking control that does
                nothing is exactly what the composer rule exists to prevent. /clear stays live —
                it routes to clear_talk/1 and is safe mid-turn. --%>
          <button
            :for={label <- slash_chips(@awaiting?)}
            :if={!@busy? or label == slash_clear()}
            type="button"
            phx-click="talk_slash"
            phx-value-text={label}
            style={mono_family() <> "font-size:10.5px;font-weight:500;padding:4px 8px;border-radius:5px;border:1px solid oklch(0.3 0.02 262);background:oklch(0.22 0.018 262);color:oklch(0.72 0.02 262);"}
          >
            {label}
          </button>
        </div>
        <div style="display:flex;align-items:center;gap:9px;">
          <span style={mono_family() <> "font-size:10.5px;color:oklch(0.74 0.02 262);flex:1;min-width:0;"}>
            scrollback kept · esc back to the card
          </span>
          <button
            :if={@busy?}
            type="button"
            id={"#{@id}-stop"}
            phx-click="talk_stop"
            style={mono_family() <> "flex:0 0 auto;font-size:10px;font-weight:600;padding:4px 8px;border-radius:5px;border:1px solid oklch(0.32 0.03 220);background:oklch(0.23 0.03 220);color:oklch(0.76 0.1 220);"}
          >
            stop
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp mono, do: "font-family:'JetBrains Mono',ui-monospace,monospace;font-size:11.5px;line-height:19px;"

  # For the elements the artboard sets its own `font-size` on with NO `line-height` override
  # (title bar, footer copy, slash chips) — concatenating `mono()` would leave a stray
  # `line-height:19px` behind after the font-size override, which is not what the artboard draws.
  defp mono_family, do: "font-family:'JetBrains Mono',ui-monospace,monospace;"

  @doc """
  The one slash command the pane handles itself rather than posting as a turn — so it is the one
  chip that stays live while a turn is in flight. Defined here and called by `BoardLive`, rather
  than the literal being typed in both places (AGENTS.md: a magic value is defined exactly once).
  """
  def slash_clear, do: "/clear"

  # Artboard line 829: the lead chip and the composer placeholder both depend on whether the
  # card is parked — "why is this stuck?" when it is, "why did review reject?" / "what happened?"
  # when it is not. Hardcoding the not-parked wording asked the wrong question on exactly the
  # cards Talk exists for.
  defp slash_chips(awaiting?), do: [lead_chip(awaiting?), "fix it", "/card", "/run", slash_clear()]

  defp lead_chip(true), do: "why is this stuck?"
  defp lead_chip(false), do: "why did review reject?"

  defp lead_prompt(true), do: "why is this stuck?"
  defp lead_prompt(false), do: "what happened?"

  defp out_color(%{dim: true}), do: "oklch(0.58 0.03 262)"
  defp out_color(_event), do: "oklch(0.86 0.015 262)"

  # The busy/idle clauses differ only in bg/fg — shared here so neither can drift out of sync,
  # and so the JetBrains Mono stack is spelled out once (via `mono_family/0`) instead of twice.
  defp chip_style(busy?) do
    {bg, fg} =
      if busy?,
        do: {"oklch(0.28 0.05 300)", "oklch(0.82 0.09 300)"},
        else: {"oklch(0.26 0.02 262)", "oklch(0.68 0.02 262)"}

    "display:inline-flex;align-items:center;height:18px;padding:0 7px;border-radius:4px;flex:0 0 auto;" <>
      mono_family() <> "font-size:9.5px;font-weight:600;letter-spacing:0.04em;background:#{bg};color:#{fg};"
  end

  # One component serves both LiveView (`@stream`, a `Phoenix.LiveView.LiveStream` yielding
  # `{dom_id, item}`) and Storybook/tests (`@events`, a plain list) — the DOM id is only
  # meaningful (and only needed) for the stream.
  defp transcript_items(%{stream: stream}) when not is_nil(stream), do: stream
  defp transcript_items(%{events: events}) when is_list(events), do: Enum.map(events, &{nil, &1})
  defp transcript_items(_assigns), do: []
end
