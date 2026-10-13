defmodule RelayWeb.SetupComponents do
  @moduledoc """
  The board's **setup wizard** (RE443, card mockups "Wizard — docked left on the empty board,
  every step state + expert toggle" and "Mobile — read-only checklist, continue on a
  computer"), rendered by `RelayWeb.BoardLive` from `Relay.Setup.checklist/1`.

    * `setup_checklist/1` — the ONE checklist renderer: a marker, title, actor tag, *why* line,
      evidence and *what this does* per step, in `:interactive` mode (step 2's LLM picker, step
      3's shown-once key, step 4's install command and preflight checks) or `:read_only` mode
      (no controls; each unfinished step shows its `read_only_note`).
    * `setup_panel/1` — the docked-left wizard: header, progress, expert toggle,
      `how_relay_works/1`, the interactive checklist and a footer.
    * `setup_chip/1` — the top-bar `Setup · <position> of 7` chip.
    * `setup_mobile/1` — what a phone sees instead of the columns: "Continue on a computer" and
      the read-only checklist.

  Whose move it is is the step's colour: `you · here` / `you · terminal` are primary (blue),
  `AI · terminal` is secondary (violet); done is success, failed is error. Theme tokens only.

  Every DOM id inside a checklist is prefixed by its `id` (`<id>-step-5-1`, `<id>-llm-form`,
  `<id>-key-box`, `<id>-install-command`, …), so the panel (`id="setup"`) and the mobile view
  can both be on the page. Events, all handled by `RelayWeb.BoardLive`: `"setup_select_llm"`
  (the LLM form's `phx-change`, `%{"llm" => harness}`), `"setup_choose_llm"`
  (`%{"llm" => harness}`), `"setup_mint_key"`, `"setup_toggle_explanations"`,
  `"setup_minimize"` and `"setup_open"`.

  Stories: `storybook/setup_components/`.
  """

  use RelayWeb, :html

  alias Relay.Setup
  alias Schemas.BoardSetupStep

  @muted "color:color-mix(in oklab, var(--color-base-content) 55%, transparent)"
  @faint "color:color-mix(in oklab, var(--color-base-content) 40%, transparent)"

  # The panel is one per page: its controls and its checklist use the `setup-` ids the board's
  # tests and smoke address.
  @panel_prefix "setup"

  # ---------------------------------------------------------------- checklist

  attr :id, :string, required: true, doc: "the list's DOM id, and the prefix of every id inside it"
  attr :checklist, :map, required: true, doc: "`Relay.Setup.checklist/1`"
  attr :mode, :atom, values: [:interactive, :read_only], default: :interactive
  attr :hide_explanations, :boolean, default: false, doc: "hide the why lines and What-this-does"
  attr :token, :string, default: nil, doc: "the shown-once step-3 key, only while it's on screen"
  attr :install_command, :string, default: nil, doc: "`Relay.Setup.install_command/2` for this board"
  attr :selected_llm, :string, default: nil, doc: "the harness key the step-2 picker has selected"
  attr :board_slug, :string, default: nil, doc: "for the \"switch the default LLM\" settings link"

  def setup_checklist(assigns) do
    assigns = assign(assigns, :last_id, List.last(assigns.checklist.steps).id)

    ~H"""
    <ol id={@id} class="flex flex-col">
      <.setup_step
        :for={step <- @checklist.steps}
        prefix={@id}
        step={step}
        last={step.id == @last_id}
        checklist={@checklist}
        interactive={@mode == :interactive}
        explain={@mode == :interactive and not @hide_explanations}
        token={@token}
        install_command={@install_command}
        selected_llm={@selected_llm}
        board_slug={@board_slug}
      />
    </ol>
    """
  end

  attr :prefix, :string, required: true
  attr :step, :map, required: true
  attr :last, :boolean, required: true
  attr :checklist, :map, required: true
  attr :interactive, :boolean, required: true
  attr :explain, :boolean, required: true
  attr :token, :string, required: true
  attr :install_command, :string, required: true
  attr :selected_llm, :string, required: true
  attr :board_slug, :string, required: true

  defp setup_step(assigns) do
    step = assigns.step
    finished? = step.status in BoardSetupStep.finished_statuses()

    assigns =
      assign(assigns,
        finished?: finished?,
        current?: step.status in BoardSetupStep.current_statuses(),
        tone: actor_tone(step.actor)
      )

    ~H"""
    <li id={step_dom_id(@prefix, @step.id)} data-status={@step.status} class="flex gap-3">
      <div class="setup-marker-col flex flex-col items-center">
        <span class="setup-marker font-mono" style={marker_style(@step.status, @tone)}>
          {marker_glyph(@step)}
        </span>
        <span
          :if={not @last}
          style="width:1.5px;flex:1;background:var(--color-base-300);margin:4px 0 -4px 0"
        >
        </span>
      </div>
      <div
        class={["flex min-w-0 flex-1 flex-col gap-1.5", not @last && "pb-4"]}
        style="padding-top:2px"
      >
        <div class="flex flex-wrap items-center gap-2">
          <span style={title_style(@step.status)}>{@step.title}</span>
          <span
            :if={@step.status != :done}
            class="setup-actor-tag font-mono"
            style={tag_style(@tone)}
          >
            {actor_label(@step.actor)}
          </span>
        </div>
        <p
          :if={@explain and not @finished? and @step.why}
          class="setup-why"
          style={"font-size:12.5px;line-height:1.45;" <> muted()}
        >
          {@step.why}
        </p>
        <p
          :if={not @interactive and not @finished? and @step.read_only_note}
          class="setup-read-only-note"
          style={"font-size:12.5px;line-height:1.45;" <> muted()}
        >
          {@step.read_only_note}
        </p>
        <.llm_picker
          :if={@interactive and @current? and @step.id == Setup.step_id(:llm)}
          prefix={@prefix}
          selected={@selected_llm}
        />
        <.key_box
          :if={@interactive and @current? and @step.id == Setup.step_id(:key)}
          prefix={@prefix}
          token={@token}
        />
        <.install_block
          :if={@interactive and @current? and @step.id == Setup.step_id(:install)}
          prefix={@prefix}
          step={@step}
          llm={@checklist.llm}
          install_command={@install_command}
          board_slug={@board_slug}
        />
        <div
          :if={@step.evidence && evidence_glyph(@step.status)}
          class={[
            "setup-evidence flex items-center gap-1.5 font-mono",
            @step.status == :waiting && "animate-pulse"
          ]}
          style={evidence_style(@step.status, @tone)}
        >
          <span>{evidence_glyph(@step.status)} {@step.evidence}</span>
        </div>
        <.preflight_checks
          :if={@interactive and @current? and @step.id == Setup.step_id(:install)}
          prefix={@prefix}
          checks={List.wrap(@step.data["checks"])}
        />
        <details :if={@explain and @current? and @step.what_this_does != []} class="setup-what">
          <summary
            class="link link-hover flex cursor-pointer list-none items-center gap-1.5"
            style="font-size:12px;color:color-mix(in oklab, var(--color-primary) 70%, var(--color-base-content))"
          >
            <span class="font-mono" style={"font-size:10px;" <> faint()}>▸</span> What this does
          </summary>
          <ul class="mt-1.5 flex list-disc flex-col gap-1 pl-5" style={"font-size:12px;" <> muted()}>
            <li :for={line <- @step.what_this_does}>{line}</li>
          </ul>
        </details>
        <ul :if={@step.children != []} class="flex flex-col gap-1">
          <li
            :for={child <- @step.children}
            id={step_dom_id(@prefix, child.id)}
            data-status={child.status}
            class="flex items-baseline gap-2"
          >
            <span class="font-mono" style={"font-size:10.5px;" <> faint()}>{child.id}</span>
            <span style={"font-size:12px;" <> child_title_style(child.status)}>{child.title}</span>
          </li>
        </ul>
      </div>
    </li>
    """
  end

  attr :prefix, :string, required: true
  attr :selected, :string, required: true

  defp llm_picker(assigns) do
    llms = Setup.onboarding_llms()
    selected = Enum.find(llms, &(&1.harness == assigns.selected)) || Enum.find(llms, & &1.recommended?)

    assigns = assign(assigns, llms: llms, selected: selected, form: to_form(%{"llm" => selected.harness}))

    ~H"""
    <.form
      for={@form}
      id={"#{@prefix}-llm-form"}
      phx-change="setup_select_llm"
      class="flex flex-col gap-1.5"
    >
      <label
        :for={llm <- @llms}
        for={"#{@prefix}-llm-#{llm.harness}"}
        class={[
          "flex items-start gap-2.5 rounded-lg bg-base-100 p-2.5",
          if(llm.enabled?, do: "cursor-pointer", else: "cursor-not-allowed opacity-60")
        ]}
        style={
          if(llm.harness == @selected.harness,
            do: "border:2px solid var(--color-primary)",
            else: "border:1px solid var(--color-base-300);margin:1px"
          )
        }
      >
        <input
          type="radio"
          name="llm"
          id={"#{@prefix}-llm-#{llm.harness}"}
          value={llm.harness}
          class="radio radio-primary radio-xs mt-0.5"
          checked={llm.harness == @selected.harness}
          disabled={not llm.enabled?}
        />
        <span class="flex min-w-0 flex-col gap-0.5">
          <span class="flex flex-wrap items-center gap-1.5" style="font-size:13px;font-weight:600">
            {llm.label}
            <code class="font-mono" style={"font-size:10.5px;font-weight:400;" <> muted()}>
              {llm.cli}
            </code>
            <span :if={not llm.enabled?} class="badge badge-ghost badge-xs">coming soon</span>
          </span>
          <span style={"font-size:11.5px;" <> muted()}>{llm.blurb}</span>
        </span>
      </label>
    </.form>
    <button
      type="button"
      id={"#{@prefix}-use-llm"}
      phx-click="setup_choose_llm"
      phx-value-llm={@selected.harness}
      class="btn btn-primary btn-sm self-start"
    >
      Use {@selected.label}
    </button>
    """
  end

  attr :prefix, :string, required: true
  attr :token, :string, required: true

  defp key_box(%{token: nil} = assigns) do
    ~H"""
    <button
      type="button"
      id={"#{@prefix}-mint-key"}
      phx-click="setup_mint_key"
      class="btn btn-sm self-start"
    >
      Mint a new key
    </button>
    <p style={"font-size:11.5px;" <> muted()}>
      The key was shown once. Mint a new one to see it again; the unseen one stops working.
    </p>
    """
  end

  defp key_box(assigns) do
    ~H"""
    <div
      id={"#{@prefix}-key-box"}
      class="flex flex-col gap-1.5 rounded-lg p-2.5"
      style="background:color-mix(in oklab, var(--color-warning) 8%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 40%, var(--color-base-100))"
    >
      <div style="font-size:12px;font-weight:600;color:color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content))">
        Shown once. Copy it now.
      </div>
      <.code_row id={"#{@prefix}-key-line"} text={"export RELAY_API_KEY=#{@token}"} label="Copy key" />
      <div style={"font-size:11.5px;" <> muted()}>
        Put it wherever you keep secrets: <code class="font-mono">.envrc</code>, your shell profile,
        1Password. Relay never writes it to disk.
      </div>
    </div>
    """
  end

  attr :prefix, :string, required: true
  attr :step, :map, required: true
  attr :llm, :map, required: true
  attr :install_command, :string, required: true
  attr :board_slug, :string, required: true

  defp install_block(assigns) do
    data = assigns.step.data

    assigns =
      assign(assigns,
        headline: data["headline"] || assigns.step.error,
        fix: data["fix"],
        fix_command: data["fix_command"]
      )

    ~H"""
    <div
      :if={@step.status == :failed}
      id={"#{@prefix}-install-failure"}
      class="flex flex-col gap-1.5 rounded-lg p-2.5"
      style="background:color-mix(in oklab, var(--color-error) 7%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 40%, var(--color-base-100))"
    >
      <div
        :if={@headline}
        style="font-size:12.5px;font-weight:600;color:color-mix(in oklab, var(--color-error) 65%, var(--color-base-content))"
      >
        {@headline}
      </div>
      <div :if={@fix} style={"font-size:12px;" <> muted()}>{@fix}</div>
      <.code_row
        :if={@fix_command}
        id={"#{@prefix}-fix-command"}
        text={@fix_command}
        label="Copy fix command"
      />
      <div :if={@board_slug} style={"font-size:11.5px;" <> muted()}>
        Or <.link navigate={~p"/board/#{@board_slug}/settings"} class="link link-primary">
          switch the default LLM
        </.link>.
      </div>
    </div>
    <.code_row
      :if={@install_command}
      id={"#{@prefix}-install-command"}
      text={@install_command}
      label="Copy install command"
    />
    <div style={"font-size:11.5px;" <> muted()}>
      Run it at the root of your repo. It checks first, then tells you everything it's about to write.
    </div>
    <div
      id={"#{@prefix}-then"}
      class="flex items-start gap-2 rounded-lg bg-base-200 px-2.5 py-2"
      style="font-size:12px"
    >
      <span
        class="font-mono"
        style="font-weight:700;color:color-mix(in oklab, var(--color-secondary) 70%, var(--color-base-content))"
      >
        then
      </span>
      <span>
        Open <code class="font-mono">{@llm.cli}</code>
        in the same folder and run <code class="font-mono">/relay-onboard</code>.
      </span>
    </div>
    """
  end

  attr :prefix, :string, required: true
  attr :checks, :list, required: true

  defp preflight_checks(assigns) do
    ~H"""
    <div :if={@checks != []} id={"#{@prefix}-preflight-checks"} class="mt-0.5 flex flex-col gap-1">
      <div :for={check <- @checks} class="flex min-w-0 items-center gap-2" style="font-size:12.5px">
        <span class="font-mono" style={check_mark_style(check["ok"])}>
          {if(check["ok"], do: "✓", else: "!")}
        </span>
        <span class="flex-none">{check["label"]}</span>
        <span class="flex-1"></span>
        <span class="truncate font-mono" style={"font-size:10.5px;" <> muted()}>
          {check["detail"]}
        </span>
      </div>
    </div>
    """
  end

  # A code line with the shared Copy control; `id` is the row's.
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, required: true

  defp code_row(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex items-stretch overflow-hidden rounded-lg border border-base-300 bg-base-200"
    >
      <code
        class="min-w-0 flex-1 px-3 py-2 font-mono"
        style="font-size:12px;white-space:nowrap;overflow-x:auto"
      >
        {@text}
      </code>
      <.copy_button id={"#{@id}-copy"} text={@text} label={@label} class="self-center mx-1" />
    </div>
    """
  end

  # ---------------------------------------------------------------- panel

  attr :id, :string, required: true
  attr :checklist, :map, required: true, doc: "`Relay.Setup.checklist/1`"
  attr :board_name, :string, required: true
  attr :hide_explanations, :boolean, default: false
  attr :token, :string, default: nil
  attr :install_command, :string, default: nil
  attr :selected_llm, :string, default: nil
  attr :board_slug, :string, default: nil
  attr :class, :any, default: "flex", doc: "the aside's display classes (BoardLive: `hidden drawer:flex`)"

  def setup_panel(assigns) do
    assigns =
      assign(assigns,
        prefix: @panel_prefix,
        progress: round(assigns.checklist.done_count * 100 / length(assigns.checklist.steps)),
        warn?: assigns.checklist.template_warning && assigns.checklist.current_id == Setup.step_id(:llm)
      )

    ~H"""
    <aside
      id={@id}
      class={[
        "w-[400px] flex-[0_0_400px] min-h-0 flex-col border-r border-base-300 bg-base-100",
        @class
      ]}
      aria-label="Setup"
    >
      <div class="flex flex-col gap-2.5 border-b border-base-300 px-4 pb-3 pt-4">
        <div class="flex items-center gap-2">
          <.setup_label />
          <span class="font-mono" style={"font-size:10.5px;" <> muted()}>
            {@checklist.position} of {length(@checklist.steps)}
          </span>
          <span class="flex-1"></span>
          <button
            type="button"
            id={"#{@prefix}-minimize"}
            phx-click="setup_minimize"
            class="btn btn-ghost btn-xs btn-square"
            aria-label="Minimize"
          >
            ⟨
          </button>
        </div>
        <h2 class="font-semibold tracking-tight" style="font-size:18px">Set up {@board_name}</h2>
        <progress class="progress progress-primary h-1.5 w-full" value={@progress} max="100">
        </progress>
        <label class="flex cursor-pointer items-center gap-2" style={"font-size:12px;" <> muted()}>
          <input
            type="checkbox"
            id={"#{@prefix}-explanations-toggle"}
            class="toggle toggle-xs"
            checked={@hide_explanations}
            phx-click="setup_toggle_explanations"
          /> I know Relay, hide explanations
        </label>
      </div>
      <div class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-4 py-4">
        <div
          :if={@warn?}
          id={"#{@prefix}-template-warning"}
          class="flex items-start gap-2 rounded-lg px-2.5 py-2"
          style="background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 40%, var(--color-base-100));font-size:11.5px;color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content))"
        >
          <span>⚠</span>
          <span>
            <b>{@checklist.template}</b>
            boards run Claude Code, Codex and Gemini. Your default runs most nodes; sign the other two
            in before the plan stage runs. Missing ones become <span class="font-mono">#setup</span>
            cards.
          </span>
        </div>
        <.how_relay_works :if={not @hide_explanations} id={"#{@prefix}-how-relay-works"} />
        <.setup_checklist
          id={@prefix}
          checklist={@checklist}
          mode={:interactive}
          hide_explanations={@hide_explanations}
          token={@token}
          install_command={@install_command}
          selected_llm={@selected_llm}
          board_slug={@board_slug}
        />
      </div>
      <div
        class="flex items-center gap-2 border-t border-base-300 px-4 py-3"
        style={"font-size:12px;" <> muted()}
      >
        <span>Stuck? Every step says how to fix it.</span>
        <span class="flex-1"></span>
        <button
          type="button"
          id={"#{@prefix}-minimize-footer"}
          phx-click="setup_minimize"
          class="link link-hover"
        >
          Minimize
        </button>
      </div>
    </aside>
    """
  end

  attr :id, :string, required: true

  def how_relay_works(assigns) do
    ~H"""
    <details id={@id} open class="rounded-xl border border-base-300 bg-base-100 p-3">
      <summary class="cursor-pointer list-none" style="font-size:12px;font-weight:600">
        <span class="font-mono" style={"font-size:10px;" <> faint()}>▾</span> How Relay works
      </summary>
      <div class="mt-2 flex items-center gap-1.5">
        <.diagram_box glyph="🌐" name="Board" caption="cloud · cards, flows" tone="primary" />
        <span class="flex-none font-mono" style={"font-size:12px;" <> faint()}>⇄</span>
        <.diagram_box
          glyph="💻"
          name="Runner"
          caption="./relay · your machine"
          tone="base-content"
        />
        <span class="flex-none font-mono" style={"font-size:12px;" <> faint()}>→</span>
        <.diagram_box glyph="✦" name="Your LLM" caption="in your repo" tone="secondary" />
      </div>
      <p class="mt-2" style={"font-size:11.5px;line-height:1.45;" <> muted()}>
        🔒 Your code never leaves your machine except through your own git pushes. The board sees
        cards, flows and run status.
      </p>
    </details>
    """
  end

  attr :glyph, :string, required: true
  attr :name, :string, required: true
  attr :caption, :string, required: true
  attr :tone, :string, required: true

  defp diagram_box(assigns) do
    ~H"""
    <div
      class="flex min-w-0 flex-1 flex-col items-center gap-0.5 rounded-lg px-2 py-2 text-center"
      style={"background:color-mix(in oklab, var(--color-#{@tone}) 8%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-#{@tone}) 35%, var(--color-base-100))"}
    >
      <span style="font-size:15px">{@glyph}</span>
      <span style="font-size:11.5px;font-weight:600">{@name}</span>
      <span class="font-mono" style={"font-size:9.5px;" <> muted()}>{@caption}</span>
    </div>
    """
  end

  # ---------------------------------------------------------------- chip

  attr :id, :string, required: true
  attr :checklist, :map, required: true, doc: "`Relay.Setup.checklist/1`"
  attr :click, :string, default: nil, doc: "the event a click sends, or nil for a plain badge"

  def setup_chip(assigns) do
    assigns =
      assign(assigns,
        label: "Setup · #{assigns.checklist.position} of #{length(assigns.checklist.steps)}",
        style:
          "background:color-mix(in oklab, var(--color-primary) 12%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-primary) 40%, var(--color-base-100));color:color-mix(in oklab, var(--color-primary) 65%, var(--color-base-content))"
      )

    ~H"""
    <button
      :if={@click}
      type="button"
      id={@id}
      phx-click={@click}
      class="badge badge-sm cursor-pointer font-mono whitespace-nowrap shrink-0"
      style={@style}
      aria-label="Open setup"
    >
      {@label}
    </button>
    <span
      :if={!@click}
      id={@id}
      class="badge badge-sm font-mono whitespace-nowrap shrink-0"
      style={@style}
    >
      {@label}
    </span>
    """
  end

  # ---------------------------------------------------------------- mobile

  attr :id, :string, required: true
  attr :checklist, :map, required: true, doc: "`Relay.Setup.checklist/1`"
  attr :class, :any, default: nil

  def setup_mobile(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-col gap-3 p-4", @class]}>
      <div
        id="setup-continue-banner"
        class="flex items-start gap-3 rounded-xl p-3.5"
        style="background:color-mix(in oklab, var(--color-primary) 8%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-primary) 40%, var(--color-base-100))"
      >
        <span style="font-size:20px">💻</span>
        <div class="flex flex-col gap-1">
          <span style="font-size:14px;font-weight:700">Continue on a computer</span>
          <span style={"font-size:12.5px;" <> muted()}>
            The next step runs in a terminal in your repo. Open this board on your computer; the
            checklist will be right where you left it.
          </span>
        </div>
      </div>
      <div class="rounded-xl border border-base-300 bg-base-100 p-4">
        <div class="mb-3 flex items-center gap-2">
          <.setup_label />
          <span class="font-mono" style={"font-size:10.5px;" <> muted()}>read-only</span>
        </div>
        <.setup_checklist id={"#{@id}-checklist"} checklist={@checklist} mode={:read_only} />
      </div>
      <p class="text-center" style={"font-size:11.5px;" <> faint()}>
        The board appears here once setup is done.
      </p>
    </div>
    """
  end

  defp setup_label(assigns) do
    ~H"""
    <span
      class="font-mono"
      style="font-size:10.5px;font-weight:600;letter-spacing:.06em;color:color-mix(in oklab, var(--color-primary) 65%, var(--color-base-content))"
    >
      SETUP
    </span>
    """
  end

  # ---------------------------------------------------------------- styles

  defp step_dom_id(prefix, step_id), do: "#{prefix}-step-#{String.replace(step_id, ".", "-")}"

  # Whose move it is: you (primary) or the AI (secondary).
  defp actor_tone(:ai_terminal), do: "secondary"
  defp actor_tone(_you), do: "primary"

  defp actor_label(:you_here), do: "you · here"
  defp actor_label(:you_terminal), do: "you · terminal"
  defp actor_label(:ai_terminal), do: "AI · terminal"

  @marker "width:24px;height:24px;border-radius:50%;flex:0 0 auto;display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;"

  defp marker_style(:done, _tone), do: @marker <> "background:var(--color-success);color:var(--color-success-content)"
  defp marker_style(:failed, _tone), do: @marker <> "background:var(--color-error);color:var(--color-error-content)"
  defp marker_style(:pending, _tone), do: @marker <> "border:1.5px solid var(--color-base-300);" <> @faint
  defp marker_style(:skipped, tone), do: marker_style(:pending, tone) <> ";border-style:dashed"

  defp marker_style(_active_or_waiting, tone) do
    @marker <>
      "background:var(--color-#{tone});color:var(--color-#{tone}-content);" <>
      "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-#{tone}) 18%, var(--color-base-100))"
  end

  defp marker_glyph(%{status: :done}), do: "✓"
  defp marker_glyph(%{status: :failed}), do: "!"
  defp marker_glyph(%{id: id}), do: id

  @title "font-size:13.5px;font-weight:600;letter-spacing:-0.01em;"

  defp title_style(:pending), do: @title <> @faint
  defp title_style(:skipped), do: @title <> @faint
  defp title_style(_status), do: @title

  defp child_title_style(:done), do: ""
  defp child_title_style(_status), do: @faint

  defp tag_style(tone) do
    text = if tone == "secondary", do: 70, else: 65

    "font-size:9.5px;font-weight:600;padding:1px 5px;border-radius:4px;" <>
      "background:color-mix(in oklab, var(--color-#{tone}) 12%, var(--color-base-100));" <>
      "color:color-mix(in oklab, var(--color-#{tone}) #{text}%, var(--color-base-content))"
  end

  defp evidence_style(status, tone) do
    color =
      case status do
        :done -> "success"
        :failed -> "error"
        :waiting -> tone
      end

    "font-size:10.5px;color:color-mix(in oklab, var(--color-#{color}) 75%, var(--color-base-content))"
  end

  defp evidence_glyph(:done), do: "✓"
  defp evidence_glyph(:failed), do: "✕"
  defp evidence_glyph(:waiting), do: "◌"
  # Pending, active and skipped steps show no evidence line.
  defp evidence_glyph(_status), do: nil

  defp check_mark_style(ok) do
    color = if ok, do: "success", else: "error"
    "width:12px;font-weight:700;color:color-mix(in oklab, var(--color-#{color}) 70%, var(--color-base-content))"
  end

  defp muted, do: @muted
  defp faint, do: @faint
end
