defmodule RelayWeb.TemplatePickerComponents do
  @moduledoc """
  The **New board** template picker (RE442, card mockup "Picker — New board opens three
  template cards"): a modal of radio cards, one per `Relay.Boards.templates/0` entry, each
  showing the template's main-stage strip (type glyph + name, a ring on stages with a Review
  sub-lane, never a WIP limit), blurb, facts row and optional warning, over a footer whose
  primary button reads "Create board from <name>".

  Selection is the caller's assign (`selected`): the radios' `checked` and the selected card's
  border both come from it, so what's shown and what's submitted can't disagree. Events, all
  handled by `RelayWeb.BoardsLive`:

    * `"select_template"` — the form's `phx-change`, `%{"template" => slug}`
    * `"create_from_template"` — the form's `phx-submit`, `%{"template" => slug}`
    * `"close_template_picker"` — Cancel, ✕, a scrim click or Escape

  The mockup's "See the public example" links are deliberately not rendered yet (RE444); each
  card keeps the `flex-1` spacer they will sit under. Story:
  `storybook/template_picker_components/template_picker.story.exs`.
  """

  use RelayWeb, :html

  attr :templates, :list, required: true, doc: "`Relay.Boards.templates/0`, in picker order"
  attr :selected, :string, required: true, doc: "the selected template's slug"
  attr :id, :string, default: "template-picker"

  def template_picker(assigns) do
    assigns =
      assign(assigns,
        form: to_form(%{"template" => assigns.selected}),
        selected_name: selected_name(assigns.templates, assigns.selected)
      )

    ~H"""
    <div id={@id} phx-window-keydown="close_template_picker" phx-key="escape">
      <.modal_scrim phx-click="close_template_picker" />
      <div class="fixed inset-x-0 top-0 z-[51] flex max-h-screen justify-center overflow-y-auto p-0 sm:p-6">
        <div
          id={"#{@id}-panel"}
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-title"}
          class="bg-base-200 w-full sm:max-w-[1080px] sm:rounded-[18px] shadow-xl flex flex-col border border-base-300"
        >
          <div class="flex items-start gap-3 px-5 pt-5 pb-3">
            <div class="flex flex-col gap-1">
              <h2 id={"#{@id}-title"} class="font-semibold tracking-tight text-[20px]">New board</h2>
              <p class="text-[13.5px] text-base-content/55 max-w-[640px]">
                Start from a template. You get its stages and flows. Every prompt lives inside its flow, so it works in any repo with no
                <span class="font-mono">.claude/</span>
                setup.
              </p>
            </div>
            <span class="flex-1"></span>
            <button
              type="button"
              id={"#{@id}-close"}
              phx-click="close_template_picker"
              class="btn btn-ghost btn-sm btn-square"
              aria-label="Close"
            >
              ✕
            </button>
          </div>

          <.form
            for={@form}
            id={"#{@id}-form"}
            phx-change="select_template"
            phx-submit="create_from_template"
          >
            <div id={"#{@id}-grid"} class="grid gap-4 px-5 pb-4 grid-cols-1 md:grid-cols-3">
              <.template_card :for={t <- @templates} template={t} selected?={t.slug == @selected} />
            </div>

            <div class="flex flex-wrap items-center gap-3 px-5 py-4 border-t border-base-300 bg-base-100 sm:rounded-b-[18px]">
              <span class="flex-1"></span>
              <button
                type="button"
                id={"#{@id}-cancel"}
                phx-click="close_template_picker"
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
              <.button
                type="submit"
                id={"#{@id}-create"}
                class="btn btn-primary btn-sm w-full sm:w-auto"
                pending="Creating…"
              >
                Create board from {@selected_name}
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  attr :template, :map, required: true
  attr :selected?, :boolean, required: true

  defp template_card(assigns) do
    ~H"""
    <label
      id={"template-card-#{@template.slug}"}
      class={[
        "flex flex-col gap-3 rounded-[14px] bg-base-100 p-4 cursor-pointer",
        if(@selected?, do: "border-2 border-primary", else: "border border-base-300 m-px")
      ]}
      style={
        @selected? &&
          "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100));"
      }
    >
      <div class="flex items-start gap-3">
        <input
          type="radio"
          id={"template-radio-#{@template.slug}"}
          name="template"
          value={@template.slug}
          checked={@selected?}
          class="radio radio-primary radio-sm mt-0.5"
        />
        <div class="flex flex-col gap-0.5 min-w-0">
          <span class="font-semibold text-[15px]">{@template.name}</span>
          <span class="text-[13px] text-base-content/55">{@template.tagline}</span>
        </div>
      </div>

      <div
        id={"template-stages-#{@template.slug}"}
        class="flex flex-wrap items-center gap-x-1.5 gap-y-1.5 rounded-lg bg-base-200 px-2.5 py-2"
      >
        <%= for {stage, i} <- Enum.with_index(@template.stages) do %>
          <span :if={i > 0} class="template-arrow text-[10px] text-base-content/40" aria-hidden="true">
            →
          </span>
          <span class="flex items-center gap-1 font-mono text-[10.5px] whitespace-nowrap">
            <.stage_type_icon type={stage.type} size={8} />
            <span>{stage.name}</span>
            <span
              :if={:review in stage.sublanes}
              class="template-review-marker"
              title="has a Review sub-lane"
              style="width:6px;height:6px;border-radius:50%;border:1.5px solid var(--color-warning);display:inline-block;"
            >
            </span>
          </span>
        <% end %>
      </div>

      <p class="text-[12.5px] leading-[1.5] text-base-content/75">{@template.blurb}</p>

      <div id={"template-facts-#{@template.slug}"} class="flex flex-wrap gap-x-3 gap-y-1">
        <span class="font-mono text-[10.5px] text-base-content/55">
          {count_label(length(@template.stages), "stage")}
        </span>
        <span class="font-mono text-[10.5px] text-base-content/55">
          {count_label(length(@template.flows), "flow")}
        </span>
        <span
          class="font-mono text-[10.5px]"
          style="color:color-mix(in oklab, var(--color-success) 65%, var(--color-base-content));"
        >
          {count_label(skill_count(@template), "skill")}
        </span>
      </div>

      <div
        :if={@template.warning}
        id={"template-warning-#{@template.slug}"}
        class="flex items-start gap-2 rounded-lg px-2.5 py-2 text-[11.5px]"
        style="background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 40%, var(--color-base-100));color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content));"
      >
        <span aria-hidden="true">⚠</span>
        <span>{@template.warning}</span>
      </div>

      <%!-- RE444 puts the "See the public example" link under this spacer. --%>
      <span class="flex-1"></span>
    </label>
    """
  end

  defp selected_name(templates, slug) do
    case Enum.find(templates, &(&1.slug == slug)) do
      nil -> ""
      template -> template.name
    end
  end

  # A "skill" is a flow node bound to a `.claude/` agent; every template's prompts are inline,
  # so this derives to 0 — but it is derived, so a template that does bind one says so.
  defp skill_count(template) do
    template.flows
    |> Enum.flat_map(& &1.nodes)
    |> Enum.count(&(Map.get(&1, :agent) not in [nil, ""]))
  end

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(n, noun), do: "#{n} #{noun}s"
end
