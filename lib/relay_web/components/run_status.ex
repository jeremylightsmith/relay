defmodule RelayWeb.RunStatus do
  @moduledoc """
  The single `run status → {label, color-token, icon}` map (RLY-207). Collapses
  the three independent status→label/icon tables that the run strip, card face,
  and history chip each used to carry. `label` states only what the status
  guarantees — no cause the data doesn't back (no "merged", no "claimed"). Each
  surface keeps its own size/layout and casing; it reads label/token/icon here.
  """

  use Phoenix.Component

  @descriptors %{
    running: %{label: "Running", token: "--color-secondary", icon: "●"},
    parked: %{label: "Parked", token: "--color-warning", icon: "?"},
    failed: %{label: "Run failed", token: "--color-error", icon: "!"},
    done: %{label: "Completed", token: "--color-success", icon: "✓"},
    cancelled: %{label: "Cancelled", token: "--color-neutral", icon: "⊘"}
  }

  @doc "The `%{label, token, icon}` descriptor for a `Schemas.Run` status."
  def descriptor(status) when is_map_key(@descriptors, status), do: Map.fetch!(@descriptors, status)

  @doc "Storybook-only: renders one status row (icon swatch + status + label + token)."
  attr :status, :atom, required: true

  def descriptor_row(assigns) do
    assigns = assign(assigns, :d, descriptor(assigns.status))

    ~H"""
    <div
      class="run-status-row"
      style="display:flex;align-items:center;gap:12px;font-family:var(--font-mono);font-size:12px;padding:6px 0;"
    >
      <span style={"display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;border-radius:50%;background:var(#{@d.token});color:oklch(1 0 0);"}>
        {@d.icon}
      </span>
      <span style="width:90px;font-weight:600;">{@status}</span>
      <span style="width:120px;">{@d.label}</span>
      <span style="color:oklch(0.55 0.02 255);">{@d.token}</span>
    </div>
    """
  end
end
