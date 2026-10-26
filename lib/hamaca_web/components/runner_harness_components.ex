defmodule HamacaWeb.RunnerHarnessComponents do
  @moduledoc """
  The Runners page's per-runner **HARNESSES** section (RE436, card mockup "Runners: per-harness
  rows draw whatever usage windows the harness defines").

  `runner_harnesses/1` renders `Hamaca.Runs.runner_harness_rows/4`'s rows as a HARNESS / VERSION /
  SIGNED IN / USAGE table. Nothing is special-cased per harness: a row draws one labeled bar per
  window its harness's USAGE setting defines, where the reading came from and how old it is, an
  amber paused line while that harness alone is paused, and — when the runner lacks the harness —
  the board agents whose nodes it won't claim. The four-column layout is keyed to the table's OWN
  width (a Tailwind container query, `@2xl` = 42rem), not the viewport: the table sits in the runner
  card's left pane beside the log tail, ~420px even on a desktop, where fixed 150/110/120px tracks
  would crush USAGE to nothing. Narrower than that a row stacks — name and signed-in state on one
  line, usage full-width under them, the version dropped (the mockup's mobile layout).

  Self-contained like `HamacaWeb.RunComponents` (no CoreComponents import). The story lives at
  `storybook/runner_harness_components/runner_harnesses.story.exs`.
  """

  use Phoenix.Component

  alias Hamaca.Runs
  alias HamacaWeb.TimeAgo
  alias Schemas.Runner

  # The CAPACITY label idiom of `HamacaWeb.BoardRunnersLive` (artboard `.lbl`).
  @label_style "font-size:9.5px;font-weight:600;letter-spacing:0.06em;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
  @columns "grid-template-columns:150px 110px 120px 1fr;"
  @warning_ink "color:color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content));"
  @success_ink "color:color-mix(in oklab, var(--color-success) 60%, var(--color-base-content));"
  @error_ink "color:color-mix(in oklab, var(--color-error) 65%, var(--color-base-content));"

  @doc """
  The HARNESSES section for one runner. `id` is the runner panel's DOM id (`runner-<dom_id>`): the
  section is `<id>-harnesses`, each row `<id>-harness-<key>`, a paused row's line
  `<id>-harness-<key>-paused`, and each bar carries `data-usage-bar="<label>"`. `rows` is
  `Hamaca.Runs.runner_harness_rows/4`'s output; `now` dates each reading's age.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :now, DateTime, required: true

  def runner_harnesses(assigns) do
    assigns = assign(assigns, label_style: @label_style, columns: @columns, last: length(assigns.rows) - 1)

    ~H"""
    <div id={"#{@id}-harnesses"} class="flex flex-col gap-2">
      <span class="font-mono" style={@label_style}>HARNESSES · {length(@rows)}</span>
      <div class="@container border border-base-300 rounded-lg overflow-hidden">
        <div
          id={"#{@id}-harnesses-header"}
          class="hidden @2xl:grid font-mono bg-base-200 border-b border-base-300"
          style={@label_style <> @columns <> "padding:7px 12px;gap:12px;"}
        >
          <span>HARNESS</span>
          <span>VERSION</span>
          <span>SIGNED IN</span>
          <span>USAGE</span>
        </div>
        <.harness_row
          :for={{row, index} <- Enum.with_index(@rows)}
          id={"#{@id}-harness-#{row.key}"}
          row={row}
          last?={index == @last}
          now={@now}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :last?, :boolean, required: true
  attr :now, DateTime, required: true

  defp harness_row(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "grid items-center grid-cols-[minmax(0,1fr)_auto] gap-x-3 gap-y-1.5",
        "@2xl:grid-cols-[150px_110px_120px_minmax(0,1fr)] @2xl:gap-3",
        not @last? && "border-b border-base-300"
      ]}
      style={"padding:10px 12px;" <> row_tint(@row)}
    >
      <span style="font-weight:600;font-size:13px;">{@row.name}</span>
      <span
        id={"#{@id}-version"}
        class="hidden @2xl:block font-mono text-base-content/65"
        style="font-size:11.5px;"
      >
        {@row.version || "—"}
      </span>
      <span
        id={"#{@id}-signed-in"}
        class={[
          "col-start-2 row-start-1 @2xl:col-start-auto @2xl:row-start-auto",
          @row.signed_in == :na && "text-base-content/65"
        ]}
        style={"font-size:12px;" <> signed_in_ink(@row.signed_in)}
      >
        {signed_in_label(@row.signed_in)}
      </span>
      <%= if @row.installed do %>
        <div id={"#{@id}-usage"} class="col-span-full @2xl:col-span-1 min-w-0 flex flex-col gap-1.5">
          <%= if reading?(@row) do %>
            <div :for={bar <- @row.bars} class="flex items-center gap-2">
              <span class="font-mono text-base-content/65" style="font-size:10.5px;width:22px;">
                {bar.label}
              </span>
              <progress
                class={[
                  "progress flex-1",
                  if(bar.over?, do: "progress-warning", else: "progress-secondary")
                ]}
                data-usage-bar={bar.label}
                value={bar_value(bar.used_pct)}
                max="100"
                style="height:6px;"
              >
              </progress>
              <span class="font-mono" style="font-size:11px;width:30px;">
                {percent(bar.used_pct)}
              </span>
            </div>
          <% else %>
            <span class="text-base-content/65" style="font-size:12px;">—</span>
          <% end %>
          <span :if={@row.paused} id={"#{@id}-paused"} style={"font-size:11.5px;" <> warning_ink()}>
            {paused_line(@row)}
          </span>
          <span
            :if={reading?(@row)}
            id={"#{@id}-source"}
            class="text-base-content/65"
            style="font-size:11px;"
          >
            <%= if @row.source == "command" do %>
              from <span class="font-mono break-all" title={@row.command}>{@row.command}</span>{age(
                @row.read_at,
                @now
              )}
            <% else %>
              from its output{age(@row.read_at, @now)}
            <% end %>
          </span>
        </div>
      <% else %>
        <span
          id={"#{@id}-usage"}
          class="col-span-full @2xl:col-span-1 text-base-content/65"
          style="font-size:11.5px;"
        >
          {not_installed_line(@row)}
        </span>
      <% end %>
    </div>
    """
  end

  defp row_tint(%{installed: false}), do: "opacity:.75;"
  defp row_tint(%{paused: %{}}), do: "background:color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100));"
  defp row_tint(_row), do: ""

  defp signed_in_label(:yes), do: "✓ signed in"
  defp signed_in_label(:no), do: "✗ signed out"
  defp signed_in_label(:na), do: "— n/a"
  defp signed_in_label(:not_installed), do: "✗ not installed"

  defp signed_in_ink(:yes), do: @success_ink
  defp signed_in_ink(:na), do: ""
  defp signed_in_ink(_signed_out_or_missing), do: @error_ink

  defp warning_ink, do: @warning_ink

  # A harness set to "Not reported", or one with no reading yet, draws a single — instead of bars.
  defp reading?(%{source: "none"}), do: false
  defp reading?(%{read_at: nil, bars: bars}), do: Enum.any?(bars, &is_number(&1.used_pct))
  defp reading?(_row), do: true

  # The bar is capped at 100 (a Codex `used_percent` can run past it); the label keeps the real value.
  defp bar_value(nil), do: 0
  defp bar_value(used_pct), do: min(round(used_pct), 100)

  defp percent(nil), do: "—"
  defp percent(used_pct), do: "#{round(used_pct)}%"

  defp age(nil, _now), do: ""
  defp age(read_at, now), do: " · " <> TimeAgo.ago(now, read_at)

  defp paused_line(%{name: name, paused: paused, others: others}) do
    cause =
      if Runner.rejected_rate_limit?(paused),
        do: "#{name} refused a call",
        else: "#{paused.window} at #{percent(paused.used_pct)}, over #{name}'s #{paused.pause_at}% pause-at"

    "⏸ Paused — #{cause}; resets #{Runs.resume_time_label(paused.resets_at)}. #{name} nodes wait" <>
      still_claiming(others)
  end

  defp still_claiming([]), do: "."
  defp still_claiming(others), do: "; #{Enum.join(others, " and ")} nodes still claim."

  defp not_installed_line(%{agents: agents, source: source}) do
    not_reported = if source == "none", do: "Usage: not reported.", else: ""

    case agents do
      [] ->
        not_reported

      agents ->
        String.trim_trailing("Won't claim nodes that use #{Enum.map_join(agents, ", ", &"“#{&1}”")}. " <> not_reported)
    end
  end
end
