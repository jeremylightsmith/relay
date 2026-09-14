defmodule Storybook.Components.CoreComponents.ImageLightbox do
  @moduledoc false
  use PhoenixStorybook.Story, :page

  alias RelayWeb.CoreComponents

  def doc,
    do:
      "RLY-157 · click-to-enlarge; RE322 · the viewer is a carousel over the clicked image's group. " <>
        "Top: a `.md` block with an image, constrained and cursor-zoom-in. Below: the viewer's " <>
        "chrome (image_lightbox_viewer/1) forced open — a lone image (no Previous/Next, no counter) " <>
        "and a multi-image group (Previous/Next, caption, `2 / 5`). The real dialog is opened and " <>
        "stepped by assets/js/image_lightbox.js (←/→, j/k, wrap-around), which the storybook bundle " <> "does not load."

  def navigation, do: []

  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-8 p-4">
      <section>
        <div class="mb-3 font-mono text-[11px] uppercase tracking-[0.06em] text-base-content/65">
          Constrained markdown image
        </div>
        <div class="md max-w-md rounded border border-base-300 p-3">
          <p>An agent posted a screenshot:</p>
          <img src="/images/logo_light_128.png" alt="A run screenshot" />
          <p>It is capped at 100% width / 24rem tall and shows a zoom-in cursor.</p>
        </div>
      </section>

      <section>
        <div class="mb-3 font-mono text-[11px] uppercase tracking-[0.06em] text-base-content/65">
          Viewer · single image (forced open)
        </div>
        <div class="relative h-80 overflow-hidden rounded border border-base-300">
          <div class="absolute inset-0 flex items-center justify-center bg-neutral/60">
            <CoreComponents.image_lightbox_viewer
              id="image-lightbox-story-single"
              src="/images/logo_light_512.png"
              alt="solo.png"
              caption="solo.png"
            />
          </div>
        </div>
      </section>

      <section>
        <div class="mb-3 font-mono text-[11px] uppercase tracking-[0.06em] text-base-content/65">
          Viewer · multi-image carousel (forced open)
        </div>
        <div class="relative h-80 overflow-hidden rounded border border-base-300">
          <div class="absolute inset-0 flex items-center justify-center bg-neutral/60">
            <CoreComponents.image_lightbox_viewer
              id="image-lightbox-story-multi"
              src="/images/logo_dark_512.png"
              alt="Review drawer"
              caption="Review drawer — Show more expanded"
              counter="2 / 5"
            />
          </div>
        </div>
      </section>
    </div>
    """
  end
end
