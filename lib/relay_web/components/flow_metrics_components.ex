defmodule RelayWeb.FlowMetricsComponents do
  @moduledoc "Presentation components for the Flow Metrics tab (RLY-209)."
  use Phoenix.Component

  # Artboard colors (docs/designs/Relay Flow Metrics.dc.html lines 246, 341), re-expressed as
  # daisyUI tokens (RE237) so they flip with data-theme. Kept as function results, NOT module
  # attributes — inside ~H a bare `@green` reads assigns, not an attribute.
  defp green, do: "var(--color-success)"
  defp amber, do: "var(--color-warning)"
  defp rose, do: "var(--color-error)"

  attr :id, :string, required: true
  attr :split, :map, required: true, doc: "collapsed %{ok:, needs:, fail:, ok_pct:, needs_pct:, fail_pct:, total:}"

  @doc "The 3-segment verdict split bar: green succeeded / amber needs-input / rose failed."
  def verdict_bar(assigns) do
    ~H"""
    <div id={@id}>
      <div
        title={"#{@split.ok_pct}% succeeded · #{@split.needs_pct}% needs input · #{@split.fail_pct}% failed"}
        style="display:flex;width:100%;max-width:158px;height:8px;border-radius:5px;overflow:hidden;background:var(--color-base-300);"
      >
        <div style={"height:100%;width:#{@split.ok_pct}%;background:#{green()};"} />
        <div style={"height:100%;width:#{@split.needs_pct}%;background:#{amber()};"} />
        <div style={"height:100%;width:#{@split.fail_pct}%;background:#{rose()};"} />
      </div>
      <span style={"font-family:var(--font-mono);font-size:10px;color:#{label_color(@split.fail_pct)};"}>
        {@split.ok_pct}% ok{if @split.fail_pct > 0, do: " · #{@split.fail_pct}% fail"}
      </span>
    </div>
    """
  end

  defp label_color(fail_pct) when fail_pct >= 25,
    do: "color-mix(in oklab, var(--color-error) 80%, var(--color-base-content))"

  defp label_color(_), do: "color-mix(in oklab, var(--color-base-content) 55%, transparent)"
end
