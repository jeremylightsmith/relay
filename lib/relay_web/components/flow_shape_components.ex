defmodule RelayWeb.FlowShapeComponents do
  @moduledoc """
  The loud, fixable face of a flow paused by a broken board shape (RE432, card mockup "B —
  broken-shape callouts on the paused stage rows (all four problems)").

    * `shape_callout/1` — renders one `Relay.Flows.Shape` problem under its stage row on Board
      Settings → Stages: the paused headline (`Relay.Flows.Shape.paused_detail/1`), WHAT, WHY,
      the BOARD ORDER strip and one FIX button per structured fix. A paused flow's callout is
      amber with a thick left border; a disabled flow's is the quieter dashed variant.
    * `board_order_strip/1` — the problem's `columns` as chips joined by `→`, with a `?`
      placeholder at the end the flow's stage has nothing beyond.
    * `paused_flow_banners/1` — the board's amber banner per paused flow (card mockup "C — board
      banner per paused flow, with Fix in Stages"), collapsing into one summary banner at
      `@collapse_at` paused flows.

  Every WHAT / WHY / fix label is the domain's sentence rendered verbatim
  (`Relay.Markdown.to_html/1`); this module owns only chrome words. FIX buttons send
  `"apply_shape_fix"` (`flow-key`, `index`, `action`) to `RelayWeb.BoardSettingsLive`, which
  re-reads the problem before applying anything. Stories live under
  `storybook/flow_shape_components/`.
  """

  use RelayWeb, :html

  alias Relay.Flows.Shape
  alias RelayWeb.FlowSettingsComponents

  # How many paused flows collapse the board's banners into one summary banner.
  @collapse_at 3

  @label_style "color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"

  @doc """
  The Shape callout for one `problem` (`t:Relay.Flows.Shape.problem/0`). `error` is a refusal
  sentence from a fix that failed, shown inside the callout; `read_only?` (an archived board)
  hides the FIX row.
  """
  attr :id, :string, required: true
  attr :problem, :map, required: true, doc: "a `Relay.Flows.Shape.problem()`"
  attr :error, :string, default: nil, doc: "a refusal sentence to show in the callout"
  attr :read_only?, :boolean, default: false, doc: "hides the FIX buttons"

  def shape_callout(assigns) do
    assigns =
      assigns
      |> assign(:paused?, assigns.problem.enabled)
      |> assign(:headline, headline(assigns.problem))
      |> assign(:label_style, @label_style)

    ~H"""
    <div
      id={@id}
      data-kind={@problem.kind}
      data-paused={to_string(@paused?)}
      class="flex flex-col gap-2.5 rounded-[10px] px-4 py-3.5"
      style={callout_style(@paused?)}
    >
      <div class="flex items-start gap-2.5">
        <span class="flex size-[24px] flex-none items-center justify-center rounded-full bg-warning text-[14px] font-bold text-warning-content">
          !
        </span>
        <div
          id={"#{@id}-headline"}
          class="min-w-0 flex-1 text-[15px] font-semibold leading-snug [&_p]:m-0"
          style="color:color-mix(in oklab, var(--color-warning) 25%, var(--color-base-content));"
        >
          {Relay.Markdown.to_html(@headline)}
        </div>
      </div>
      <div
        class="grid gap-x-3 gap-y-1.5 text-[13px] leading-normal drawer:pl-[34px]"
        style="grid-template-columns:auto 1fr;color:color-mix(in oklab, var(--color-warning) 20%, var(--color-base-content));"
      >
        <span class="pt-0.5 font-mono text-[11px]" style={@label_style}>WHAT</span>
        <div id={"#{@id}-what"} class="min-w-0 [&_p]:m-0">
          {Relay.Markdown.to_html(@problem.what)}
        </div>
        <span class="pt-0.5 font-mono text-[11px]" style={@label_style}>WHY</span>
        <div id={"#{@id}-why"} class="min-w-0 [&_p]:m-0">{Relay.Markdown.to_html(@problem.why)}</div>
      </div>
      <.board_order_strip id={"#{@id}-order"} columns={@problem.columns} class="drawer:ml-[34px]" />
      <div
        :if={!@read_only? and @problem.fixes != []}
        id={"#{@id}-fixes"}
        class="flex flex-wrap items-center gap-2 drawer:ml-[34px]"
      >
        <span class="mr-1 font-mono text-[11px]" style={@label_style}>FIX</span>
        <button
          :for={{fix, index} <- Enum.with_index(@problem.fixes)}
          type="button"
          id={"#{@id}-fix-#{index}"}
          phx-click="apply_shape_fix"
          phx-value-flow-key={@problem.flow_key}
          phx-value-index={index}
          phx-value-action={Atom.to_string(fix.action)}
          class={[
            "btn btn-sm h-auto min-h-8 w-full whitespace-normal py-1 text-left drawer:w-auto",
            if(index == 0, do: "btn-warning", else: "btn-outline")
          ]}
          style={index > 0 && secondary_fix_style()}
        >
          {fix.label}
        </button>
      </div>
      <p
        :if={@error}
        id={"#{@id}-refusal"}
        role="alert"
        class="text-[12.5px] font-semibold leading-normal drawer:ml-[34px]"
        style="color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));"
      >
        {@error}
      </p>
    </div>
    """
  end

  defp headline(%{enabled: true} = problem), do: Shape.paused_detail(problem)
  defp headline(%{flow_key: key}), do: "Flow **#{key}** is off — it will be paused when turned on."

  defp callout_style(true),
    do:
      "background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));" <>
        "border:1px solid color-mix(in oklab, var(--color-warning) 55%, var(--color-base-100));" <>
        "border-left:5px solid var(--color-warning);"

  defp callout_style(false),
    do:
      "background:var(--color-base-100);" <>
        "border:1px dashed color-mix(in oklab, var(--color-warning) 55%, var(--color-base-100));"

  defp secondary_fix_style,
    do:
      "border-color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-100));" <>
        "color:color-mix(in oklab, var(--color-warning) 30%, var(--color-base-content));"

  @doc """
  The BOARD ORDER strip: one chip per `column` (`t:Relay.Flows.Shape.column/0`) joined by `→`.
  The flow's own stage (`:self`) is violet, the column that breaks the rule (`:offending`) is
  dashed amber, the columns before it read as pickup and after it as drop-off. When the flow's
  stage is the first (last) column a `?` placeholder stands for the missing neighbour.
  """
  attr :id, :string, required: true
  attr :columns, :list, required: true, doc: "`[Relay.Flows.Shape.column()]`"
  attr :class, :any, default: nil

  def board_order_strip(assigns) do
    columns = assigns.columns

    assigns =
      assigns
      |> assign(:chips, chips(columns))
      |> assign(:missing_before?, match?([%{mark: :self} | _], columns))
      |> assign(:missing_after?, match?(%{mark: :self}, List.last(columns)))
      |> assign(:label_style, @label_style)

    ~H"""
    <div
      id={@id}
      class={["flex flex-wrap items-center gap-1.5 rounded-lg bg-base-100/70 px-2.5 py-2", @class]}
    >
      <span class="mr-1 font-mono text-[11px]" style={@label_style}>BOARD ORDER</span>
      <%= if @missing_before? do %>
        <span id={"#{@id}-missing-before"} style={FlowSettingsComponents.chip_style(:bad)}>?</span>
        <.arrow />
      <% end %>
      <%= for {chip, index} <- Enum.with_index(@chips) do %>
        <.arrow :if={index > 0} />
        <span
          id={"#{@id}-col-#{chip.column.stage_id}"}
          data-mark={chip.column.mark || "none"}
          style={FlowSettingsComponents.chip_style(chip.style)}
        >
          {chip.column.name}
        </span>
      <% end %>
      <%= if @missing_after? do %>
        <.arrow />
        <span id={"#{@id}-missing-after"} style={FlowSettingsComponents.chip_style(:bad)}>?</span>
      <% end %>
    </div>
    """
  end

  defp arrow(assigns) do
    ~H"""
    <span class="text-[12px] text-base-content/40">→</span>
    """
  end

  # Each column's chip style: before the flow's stage reads as pickup, after it as drop-off.
  defp chips(columns) do
    {chips, _seen_self?} =
      Enum.map_reduce(columns, false, fn column, seen_self? ->
        style =
          case column.mark do
            :self -> :works
            :offending -> :bad
            nil when seen_self? -> :lands
            nil -> :pulls
          end

        {%{column: column, style: style}, seen_self? or column.mark == :self}
      end)

    chips
  end

  @doc """
  The board's paused-flow banners: one amber banner per paused flow in `flows` (each with its
  `problem` filled, in display order), or a single summary banner once there are `@collapse_at`
  or more. Editors get a **Fix in Stages →** link to the flow's stage row (the first flow's, for
  the summary); non-editors (an archived board) get a line asking a board admin. Renders nothing
  for `[]`.
  """
  attr :id, :string, required: true
  attr :flows, :list, required: true, doc: "the paused `Schemas.Flow`s, `problem` filled"
  attr :slug, :string, required: true, doc: "the board slug, for the Stages link"
  attr :editor?, :boolean, required: true, doc: "Fix button (true) vs the ask line (false)"

  def paused_flow_banners(assigns) do
    assigns = assign(assigns, :collapsed?, length(assigns.flows) >= @collapse_at)

    ~H"""
    <div :if={@flows != []} id={@id} class="flex flex-col gap-2">
      <%= if @collapsed? do %>
        <.paused_banner
          id="paused-flows-summary-banner"
          slug={@slug}
          stage_id={hd(@flows).stage_id}
          editor?={@editor?}
        >
          <b>{length(@flows)} flows are paused</b>
          — {flow_names(@flows)} — because of how the board is laid out. No new runs start for them until it's fixed.
        </.paused_banner>
      <% else %>
        <.paused_banner
          :for={flow <- @flows}
          id={"paused-flow-banner-#{flow.key}"}
          slug={@slug}
          stage_id={flow.stage_id}
          editor?={@editor?}
        >
          <div class="[&_p]:m-0">{Relay.Markdown.to_html(banner_sentence(flow))}</div>
        </.paused_banner>
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :slug, :string, required: true
  attr :stage_id, :integer, required: true
  attr :editor?, :boolean, required: true
  slot :inner_block, required: true

  defp paused_banner(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      class="flex flex-col gap-2.5 rounded-lg px-4 py-3 text-[13.5px] drawer:flex-row drawer:items-center drawer:gap-3"
      style="background:color-mix(in oklab, var(--color-warning) 12%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 55%, var(--color-base-100));border-left:5px solid var(--color-warning);color:color-mix(in oklab, var(--color-warning) 25%, var(--color-base-content));"
    >
      <div class="flex flex-1 items-start gap-2.5">
        <span class="mt-px flex size-[22px] flex-none items-center justify-center rounded-full bg-warning text-[13px] font-bold text-warning-content">
          !
        </span>
        <div class="flex-1 leading-snug">{render_slot(@inner_block)}</div>
      </div>
      <.link
        :if={@editor?}
        id={"#{@id}-fix"}
        navigate={~p"/board/#{@slug}/settings?section=stages" <> "#stage-#{@stage_id}-row"}
        class="btn btn-sm btn-warning w-full drawer:w-auto"
      >
        Fix in Stages →
      </.link>
      <span :if={!@editor?} id={"#{@id}-ask"} class="text-[12px] opacity-80">
        Ask a board admin to fix it in Stages settings.
      </span>
    </div>
    """
  end

  defp banner_sentence(flow) do
    name = FlowSettingsComponents.flow_name(flow)

    "Flow **#{name}** is paused: #{flow.problem.why} " <>
      "No new #{name} runs will start until the board is fixed; runs already going will finish."
  end

  defp flow_names(flows) do
    {init, [last]} = flows |> Enum.map(&FlowSettingsComponents.flow_name/1) |> Enum.split(-1)
    Enum.join(init, ", ") <> " and " <> last
  end
end
