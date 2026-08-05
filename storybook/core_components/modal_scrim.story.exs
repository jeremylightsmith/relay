defmodule Storybook.Components.CoreComponents.ModalScrim do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.modal_scrim/1
  def render_source, do: :function

  # The scrim is `position:fixed;inset:0` (softened to `!absolute` here). A component story
  # renders each variation into an unpositioned host, so a bare `!absolute` still resolves
  # `inset:0` against the whole viewport and veils the docs/source panels. Give it a positioned,
  # clipped box to fill — same pattern as image_lightbox.story.exs's viewer preview.
  def template do
    """
    <div class="relative h-64 overflow-hidden rounded border border-base-300 bg-base-100" psb-code-hidden>
      <div class="flex h-full items-center justify-center text-base-content/60">
        Content behind the scrim
      </div>
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{id: :default, attributes: %{class: "!absolute"}},
      %Variation{id: :below_a_drawer, attributes: %{class: "!absolute", "phx-click": "close"}}
    ]
  end
end
