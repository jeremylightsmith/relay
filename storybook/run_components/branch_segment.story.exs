defmodule Storybook.RunComponents.BranchSegment do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.RunComponents.branch_segment/1
  def render_source, do: :function

  # branch_segment sizes itself with `flex:1.6`, so it has no width outside a flex row —
  # render it in one, as the drawer's mini bar and the card face do.
  def template do
    """
    <div style="display:flex;gap:2px;align-items:center;width:240px;">
      <.psb-variation/>
    </div>
    """
  end

  # RE440: a fan-out region's progress segment, one thin bar per branch in branch order.
  def variations do
    [
      %Variation{id: :in_flight, attributes: %{bars: [:succeeded, :running, :running]}},
      %Variation{id: :queued, attributes: %{bars: [:running, :running, :queued]}},
      %Variation{id: :joined_with_failure, attributes: %{bars: [:succeeded, :failed, :succeeded]}},
      %Variation{id: :face, attributes: %{bars: [:succeeded, :running, :running], size: :face}}
    ]
  end
end
