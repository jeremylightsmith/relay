defmodule Storybook.Components.CoreComponents.ImageLightbox do
  @moduledoc false
  use PhoenixStorybook.Story, :page

  def doc,
    do:
      "RLY-157 · click-to-enlarge. Top: a `.md` block with an image, constrained and " <>
        "cursor-zoom-in. Bottom: the viewer's chrome, forced open (the real dialog is " <>
        "opened by assets/js/image_lightbox.js, which the storybook bundle does not load)."

  def navigation, do: []

  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-8 p-4">
      <section>
        <div class="mb-3 font-mono text-[11px] uppercase tracking-[0.06em] text-base-content/60">
          Constrained markdown image
        </div>
        <div class="md max-w-md rounded border border-base-300 p-3">
          <p>An agent posted a screenshot:</p>
          <img src="/images/logo_light_128.png" alt="A run screenshot" />
          <p>It is capped at 100% width / 24rem tall and shows a zoom-in cursor.</p>
        </div>
      </section>

      <section>
        <div class="mb-3 font-mono text-[11px] uppercase tracking-[0.06em] text-base-content/60">
          Viewer (forced open)
        </div>
        <div class="relative h-80 overflow-hidden rounded border border-base-300">
          <div class="absolute inset-0 flex items-center justify-center bg-black/60">
            <img
              src="/images/logo_light_128.png"
              alt="A run screenshot, full size"
              class="max-h-full max-w-full rounded object-contain"
            />
          </div>
        </div>
      </section>
    </div>
    """
  end
end
