defmodule Storybook.Components.CoreComponents.Controls do
  @moduledoc false
  use PhoenixStorybook.Story, :page

  def doc, do: "Design System §04 · Controls — buttons, owner segmented, toggle, WIP stepper."

  def navigation, do: []

  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-8 p-4">
      <section>
        <div class="mb-3 font-mono text-[11px] uppercase tracking-[0.06em] text-base-content/60">
          Buttons
        </div>
        <div class="flex flex-wrap items-center gap-2.5">
          <button class="btn btn-sm btn-primary">Primary</button>
          <button class="btn btn-sm btn-secondary gap-2">
            <span class="size-2 rounded-[2px] bg-secondary-content"></span>Hand to AI
          </button>
          <button class="btn btn-sm btn-success">Approve</button>
          <button class="btn btn-sm btn-outline">Secondary</button>
          <button class="btn btn-sm btn-ghost">Ghost</button>
          <button class="btn btn-sm btn-error btn-outline">Delete</button>
        </div>
      </section>

      <section class="flex flex-wrap gap-10">
        <div>
          <div class="mb-3 font-mono text-[11px] uppercase tracking-[0.06em] text-base-content/60">
            Segmented
          </div>
          <div class="join">
            <button class="btn btn-sm join-item btn-active">Human</button>
            <button class="btn btn-sm join-item">AI</button>
          </div>
        </div>

        <div>
          <div class="mb-3 font-mono text-[11px] uppercase tracking-[0.06em] text-base-content/60">
            Toggle
          </div>
          <div class="flex items-center gap-4">
            <input type="checkbox" class="toggle toggle-primary" checked />
            <input type="checkbox" class="toggle" />
          </div>
        </div>

        <div>
          <div class="mb-3 font-mono text-[11px] uppercase tracking-[0.06em] text-base-content/60">
            WIP stepper
          </div>
          <div class="join border border-base-300">
            <button class="btn btn-sm btn-ghost join-item">−</button>
            <span class="join-item flex w-9 items-center justify-center font-mono text-sm">3</span>
            <button class="btn btn-sm btn-ghost join-item">+</button>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
