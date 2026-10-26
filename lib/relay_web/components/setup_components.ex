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
      `how_relay_works/1`, the interactive checklist (its `peeks` passed through) and a footer.
    * `setup_chip/1` — the top-bar `Setup · <position> of <total>` chip, `Setup · done` once
      the checklist is finished.
    * `setup_done_box/1` — the "You're set up" box atop a finished panel (RE446; RE456 points at
      the peeks: "Need a command again? Open any step below; it stays done."): Close setup
      (`"setup_close"`) and Connect another machine (`"setup_connect_another"`).
    * `setup_callout/1` — the payoff callout (RE446, card mockup "Payoff — first card turns
      violet, Settings → Setup, connect a machine", frame A): "An agent has the baton", pinned
      under the claimed card by the colocated `.SetupCallout` hook, which also rings that card
      (`data-setup-baton`). Watch it work (`"setup_callout_watch"`) and Got it (`"setup_close"`).
    * `setup_mobile/1` — what a phone sees instead of the columns: "Continue on a computer" and
      the read-only checklist.
    * Board settings → Setup (RE446, frame C): `status_line/1` (`"Finished 12 Oct, 14:42 · 7 of
      7 · 40 min"` / `"In progress · 4 of 7"`), `project_answers/1` (the 5.3 answers) and
      `setup_machines_table/1` (`Relay.Setup.machines/1`).

  Connect a machine (RE446, frame D): a checklist with `connect?: true` renders its skipped steps
  with a dashed `–` marker and muted evidence, hides the sub-steps a machine never runs
  (`Relay.Setup.connect_skips/0`) and, unsaved (`machine_id: nil`), offers "Mint my key" on step
  3. `setup_panel/1` titles it "Connect a machine to <board>" with the member note (`user_name`).

  Step 5 (RE445, frames D, F1, F2 and E of the wizard mockup) is the `/relay-onboard` loop: in
  both modes its sub-steps 5.1–5.8 render as rows with a status glyph (`✓ ▸ ◌ ! ○ –`) and their
  evidence. While it is current in `:interactive` mode it also shows the minutes since it was
  reached (`<id>-onboard-elapsed`, read off the `now` attr, default `DateTime.utc_now/0`; it
  refreshes on every report, no timer), and the block for the current sub-step: waiting for the
  PR to merge (`<id>-onboard-pr`, a waiting sub-step with a `pr_url`), the failed sub-step
  (`<id>-onboard-failed`), "Your answers n of 9" while 5.3 or 5.4 is current (`<id>-answers`)
  and 5.4's proposed changes with their agreement markers (`<id>-changes`).

  Peek at a finished step (RE456, card mockup "Peek — finished steps expand in place, stay
  done"): in `:interactive` mode every finished step but a connect's skipped ones has its title
  row as a toggle (`<id>-step-<n>-peek-toggle`, `"setup_toggle_peek"`, `%{"step" => n}`). A step
  whose id is in the `peeks` attr opens a peek box (`<id>-step-<n>-peek`) under its evidence with
  its why, What this does and what it showed while it was current: step 2's picker with the
  `current` badge (`<id>-llm-<harness>-current`) and `<id>-switch-llm`; step 3's masked key
  (`<id>-key-masked`, from the checklist's `key_hint`), a freshly minted one shown once and
  `<id>-mint-key`; step 4's install command and rerun note (`<id>-install-rerun`); step 5's
  `<id>-onboard-command`; step 6's `<id>-runner-command` and `<id>-runner-restart`. A peek never
  moves the step.

  Whose move it is is the step's colour: `you · here` / `you · terminal` are primary (blue),
  `AI · terminal` is secondary (violet); done is success, failed is error. Theme tokens only.

  Every DOM id inside a checklist is prefixed by its `id` (`<id>-step-5-1`, `<id>-llm-form`,
  `<id>-key-box`, `<id>-install-command`, …), so the panel (`id="setup"`) and the mobile view
  can both be on the page. Events, all handled by `RelayWeb.BoardLive`: `"setup_select_llm"`
  (the LLM form's `phx-change`, `%{"llm" => harness}`), `"setup_choose_llm"`
  (`%{"llm" => harness}`), `"setup_mint_key"` (also step 3's "Lost it? Mint a new key" while
  `Relay.Setup.key_unconfirmed?/1`, and its peek's "Mint a new key"), `"setup_key_saved"` (step 3's "I've saved it — next", RE455),
  `"setup_toggle_peek"` (`%{"step" => id}`), `"setup_switch_llm"` (step 2's peek,
  `%{"llm" => harness}`), `"setup_toggle_explanations"`,
  `"setup_minimize"`, `"setup_open"`, `"setup_close"`, `"setup_callout_watch"` and
  `"setup_connect_another"`.

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

  # The steps whose peek carries controls, by `Relay.Setup.step_id/1` role (RE456).
  @peek_roles [:llm, :key, :install, :onboard, :runner]

  # What step 5 and step 6 have you run.
  @onboard_command "/relay-onboard"
  @runner_command "./relay start"

  # ---------------------------------------------------------------- checklist

  attr :id, :string, required: true, doc: "the list's DOM id, and the prefix of every id inside it"
  attr :checklist, :map, required: true, doc: "`Relay.Setup.checklist/1`"
  attr :mode, :atom, values: [:interactive, :read_only], default: :interactive
  attr :hide_explanations, :boolean, default: false, doc: "hide the why lines and What-this-does"
  attr :token, :string, default: nil, doc: "the shown-once step-3 key, only while it's on screen"
  attr :install_command, :string, default: nil, doc: "`Relay.Setup.install_command/2` for this board"
  attr :selected_llm, :string, default: nil, doc: "the harness key the step-2 picker has selected"
  attr :board_slug, :string, default: nil, doc: "for the \"switch the default LLM\" settings link"
  attr :now, DateTime, default: nil, doc: "the clock step 5's elapsed time reads; nil is `DateTime.utc_now/0`"

  attr :peeks, MapSet,
    default: MapSet.new(),
    doc: "the top-level step ids whose peek is open (RE456); ignored for a step that isn't peekable"

  def setup_checklist(assigns) do
    assigns =
      assign(assigns, last_id: List.last(assigns.checklist.steps).id, now: assigns.now || DateTime.utc_now())

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
        now={@now}
        peeks={@peeks}
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
  attr :now, DateTime, required: true
  attr :peeks, MapSet, required: true

  defp setup_step(assigns) do
    step = assigns.step
    finished? = step.status in BoardSetupStep.finished_statuses()
    current? = step.status in BoardSetupStep.current_statuses()

    connect_skipped? = assigns.checklist.connect? and step.status == :skipped
    # A finished step can be peeked at (RE456): its title row toggles a box with what it showed
    # while it was current. Never in read-only mode, never a step a connect skipped.
    peekable? = assigns.interactive and finished? and not connect_skipped?

    assigns =
      assign(assigns,
        finished?: finished?,
        peekable?: peekable?,
        open?: peekable? and MapSet.member?(assigns.peeks, step.id),
        current?: current?,
        onboard?: assigns.interactive and current? and step.id == Setup.step_id(:onboard),
        tone: actor_tone(step.actor),
        connect_skipped?: connect_skipped?,
        children: visible_children(step.children, assigns.checklist.connect?)
      )

    ~H"""
    <li id={step_dom_id(@prefix, @step.id)} data-status={@step.status} class="flex gap-3">
      <div class="setup-marker-col flex flex-col items-center">
        <span
          class="setup-marker font-mono"
          style={
            if(@connect_skipped?,
              do: connect_skipped_marker(),
              else: marker_style(@step.status, @tone)
            )
          }
        >
          {if(@connect_skipped?, do: skipped_glyph(), else: marker_glyph(@step))}
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
        <button
          :if={@peekable?}
          type="button"
          id={"#{step_dom_id(@prefix, @step.id)}-peek-toggle"}
          phx-click="setup_toggle_peek"
          phx-value-step={@step.id}
          aria-expanded={to_string(@open?)}
          class={[
            "-mx-1.5 flex items-center gap-2 rounded-md px-1.5 py-0.5 text-left hover:bg-base-200",
            @open? && "bg-base-200"
          ]}
        >
          <span style={title_style(@step.status)}>{@step.title}</span>
          <span :if={@open?} class="setup-actor-tag font-mono" style={tag_style(@tone)}>
            {actor_label(@step.actor)}
          </span>
          <span class="flex-1"></span>
          <span class="flex" style={muted()}>
            <.icon
              name={if(@open?, do: "hero-chevron-down", else: "hero-chevron-right")}
              class="size-3.5"
            />
          </span>
        </button>
        <div :if={not @peekable?} class="flex flex-wrap items-center gap-2">
          <span style={title_style(@step.status)}>{@step.title}</span>
          <span
            :if={@step.status != :done}
            class="setup-actor-tag font-mono"
            style={tag_style(@tone)}
          >
            {actor_label(@step.actor)}
          </span>
          <%= if @onboard? and @step.reached_at do %>
            <span class="flex-1"></span>
            <span
              id={"#{@prefix}-onboard-elapsed"}
              class="font-mono"
              style={"font-size:10.5px;" <> faint()}
            >
              {minutes(elapsed_minutes(@step.reached_at, @now), :short)}
            </span>
          <% end %>
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
        <.onboard_blocks
          :if={@onboard?}
          prefix={@prefix}
          step={@step}
          current_sub_id={@checklist.current_sub_id}
        />
        <.llm_picker
          :if={@interactive and @current? and @step.id == Setup.step_id(:llm)}
          prefix={@prefix}
          selected={@selected_llm}
        />
        <.key_box
          :if={@interactive and @current? and @step.id == Setup.step_id(:key)}
          prefix={@prefix}
          token={@token}
          unsaved={@checklist.connect? and is_nil(@checklist.machine_id)}
        />
        <.install_block
          :if={@interactive and @current? and @step.id == Setup.step_id(:install)}
          prefix={@prefix}
          step={@step}
          llm={@checklist.llm}
          install_command={@install_command}
          board_slug={@board_slug}
        />
        <.code_row
          :if={@interactive and @current? and @step.id == Setup.step_id(:runner)}
          id={"#{@prefix}-runner-command"}
          text={runner_command()}
          label="Copy command"
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
        <button
          :if={
            @interactive and @step.id == Setup.step_id(:key) and Setup.key_unconfirmed?(@checklist)
          }
          type="button"
          id={"#{@prefix}-key-lost"}
          phx-click="setup_mint_key"
          class="link link-hover text-[11.5px] self-start"
          style={muted()}
        >
          Lost it? Mint a new key
        </button>
        <div
          :if={@connect_skipped? and @step.evidence}
          class="setup-evidence font-mono"
          style={"font-size:10.5px;" <> muted()}
        >
          {@step.evidence}
        </div>
        <.peek
          :if={@open?}
          prefix={@prefix}
          step={@step}
          checklist={@checklist}
          explain={@explain}
          token={@token}
          install_command={@install_command}
          selected_llm={@selected_llm}
        />
        <.preflight_checks
          :if={@interactive and @current? and @step.id == Setup.step_id(:install)}
          prefix={@prefix}
          checks={List.wrap(@step.data["checks"])}
        />
        <.substeps :if={@children != []} prefix={@prefix} children={@children} />
        <.what_this_does :if={@explain and @current?} lines={@step.what_this_does} />
      </div>
    </li>
    """
  end

  attr :lines, :list, required: true

  defp what_this_does(assigns) do
    ~H"""
    <details :if={@lines != []} class="setup-what">
      <summary
        class="link link-hover flex cursor-pointer list-none items-center gap-1.5"
        style="font-size:12px;color:color-mix(in oklab, var(--color-primary) 70%, var(--color-base-content))"
      >
        <span class="font-mono" style={"font-size:10px;" <> faint()}>▸</span> What this does
      </summary>
      <ul class="mt-1.5 flex list-disc flex-col gap-1 pl-5" style={"font-size:12px;" <> muted()}>
        <li :for={line <- @lines}>{line}</li>
      </ul>
    </details>
    """
  end

  # ---------------------------------------------------------------- peek (RE456)

  # A finished step's peek, card mockup "Peek — finished steps expand in place, stay done": a
  # header, the why line and What this does (when explanations show) around the step's controls.
  # It changes nothing about the step: the ids inside reuse the current-step ids, safe because a
  # step is never both current and finished.
  attr :prefix, :string, required: true
  attr :step, :map, required: true
  attr :checklist, :map, required: true
  attr :explain, :boolean, required: true
  attr :token, :string, required: true
  attr :install_command, :string, required: true
  attr :selected_llm, :string, required: true

  defp peek(assigns) do
    assigns = assign(assigns, role: Enum.find(@peek_roles, &(Setup.step_id(&1) == assigns.step.id)))

    ~H"""
    <div
      id={"#{step_dom_id(@prefix, @step.id)}-peek"}
      class="flex flex-col gap-2 rounded-lg border border-base-300 bg-base-100 p-3 mt-1"
      style="box-shadow:inset 3px 0 0 color-mix(in oklab, var(--color-success) 55%, var(--color-base-100))"
    >
      <div class="flex items-center gap-1.5 font-mono" style={"font-size:10px;" <> faint()}>
        <.icon name="hero-eye" class="size-3" /> still done · nothing here changes your progress
      </div>
      <p
        :if={@explain and @step.why}
        class="setup-why"
        style={"font-size:12.5px;line-height:1.45;" <> muted()}
      >
        {@step.why}
      </p>
      <.peek_controls
        role={@role}
        prefix={@prefix}
        checklist={@checklist}
        token={@token}
        install_command={@install_command}
        selected_llm={@selected_llm}
      />
      <.what_this_does :if={@explain} lines={@step.what_this_does} />
    </div>
    """
  end

  attr :role, :atom, required: true, doc: "the step's `Relay.Setup.step_id/1` role, nil for steps 1 and 7"
  attr :prefix, :string, required: true
  attr :checklist, :map, required: true
  attr :token, :string, required: true
  attr :install_command, :string, required: true
  attr :selected_llm, :string, required: true

  defp peek_controls(%{role: :llm} = assigns) do
    ~H"""
    <.llm_picker
      prefix={@prefix}
      selected={@selected_llm}
      current={@checklist.llm && @checklist.llm.harness}
    />
    """
  end

  defp peek_controls(%{role: :key} = assigns) do
    ~H"""
    <div
      :if={@checklist.key_hint}
      class="flex flex-col gap-1.5 rounded-lg border border-base-300 bg-base-200 p-2.5"
    >
      <div style="font-size:12px;font-weight:600">Where it went</div>
      <div
        id={"#{@prefix}-key-masked"}
        class="flex items-stretch overflow-hidden rounded-lg border border-base-300 bg-base-100"
      >
        <code
          class="min-w-0 flex-1 px-3 py-2 font-mono"
          style="font-size:12px;word-break:break-all"
        >
          {masked_key(@checklist.key_hint)}
        </code>
      </div>
      <div style={"font-size:11.5px;" <> muted()}>
        Masked: the board keeps only a hash, so there's nothing to copy.
      </div>
    </div>
    <.key_box :if={@token} prefix={@prefix} token={@token} saved_button={false} />
    <button
      type="button"
      id={"#{@prefix}-mint-key"}
      phx-click="setup_mint_key"
      class="btn btn-sm self-start"
    >
      Mint a new key
    </button>
    <div style={"font-size:11.5px;" <> muted()}>
      Lost it? Mint a new one. A key a runner already used keeps working until you revoke it in
      Board settings → API keys.
    </div>
    """
  end

  defp peek_controls(%{role: :install} = assigns) do
    ~H"""
    <.install_command prefix={@prefix} install_command={@install_command} />
    <div
      id={"#{@prefix}-install-rerun"}
      class="flex items-start gap-2 rounded-lg bg-base-200 px-2.5 py-2"
      style="font-size:12px"
    >
      <span class="flex" style={muted()}>
        <.icon name="hero-arrow-path" class="size-3.5 mt-0.5 shrink-0" />
      </span>
      <span>
        Safe to run again: rewrites <code class="font-mono">./relay</code>
        and the skill, keeps <code class="font-mono">runner.json</code>
        and <code class="font-mono">prepare-worktree.sh</code>
      </span>
    </div>
    """
  end

  defp peek_controls(%{role: :onboard} = assigns) do
    ~H"""
    <.code_row id={"#{@prefix}-onboard-command"} text={onboard_command()} label="Copy command" />
    """
  end

  defp peek_controls(%{role: :runner} = assigns) do
    ~H"""
    <.code_row id={"#{@prefix}-runner-command"} text={runner_command()} label="Copy command" />
    <div id={"#{@prefix}-runner-restart"} style={"font-size:11.5px;" <> muted()}>
      Restart it after changing env vars or updating ./relay.
    </div>
    """
  end

  # Steps 1 and 7 have nothing to do again: their peek is the why and What this does.
  defp peek_controls(assigns), do: ~H""

  # Step 3's key as the board knows it: the prefix and the last four, never the token.
  defp masked_key(%{token_prefix: prefix, last_four: last_four}),
    do: "export RELAY_API_KEY=relay_#{prefix}_••••#{last_four}"

  defp onboard_command, do: @onboard_command
  defp runner_command, do: @runner_command

  # ---------------------------------------------------------------- step 5: the onboard loop

  attr :prefix, :string, required: true
  attr :children, :list, required: true

  defp substeps(assigns) do
    ~H"""
    <ul class="mt-0.5 flex flex-col gap-1">
      <li
        :for={child <- @children}
        id={step_dom_id(@prefix, child.id)}
        data-status={child.status}
        class="flex min-w-0 items-center gap-2"
        style="font-size:12.5px"
      >
        <span
          class={["setup-substep-glyph font-mono", child.status == :waiting && "animate-pulse"]}
          style={"width:12px;font-weight:700;" <> substep_color(child.status)}
        >
          {substep_glyph(child.status)}
        </span>
        <span
          class="setup-substep-title-cell flex-none"
          style={if(child.status == :pending, do: faint(), else: "")}
        >
          <span class="font-mono" style={"font-size:10.5px;" <> faint()}>{child.id}</span>
          <span class="setup-substep-title">{child.title}</span>
        </span>
        <span class="flex-1"></span>
        <span
          :if={child.evidence}
          class="setup-substep-evidence truncate font-mono"
          style={"font-size:10.5px;" <> muted()}
        >
          {child.evidence}
        </span>
      </li>
    </ul>
    """
  end

  # Step 5's live blocks, interactive only: the waiting-for-PR block (frame D), the failed
  # sub-step (frame E), the interview answers (F1, F2) and the proposed changes (F2).
  attr :prefix, :string, required: true
  attr :step, :map, required: true
  attr :current_sub_id, :string, required: true

  defp onboard_blocks(assigns) do
    children = Map.new(assigns.step.children, &{&1.id, &1})
    current = children[assigns.current_sub_id]
    interview = children[Setup.step_id(:interview)]
    customize = children[Setup.step_id(:customize)]
    current_id = current && current.id

    assigns =
      assign(assigns,
        current: current,
        pr_url: current && current.status == :waiting && current.data["pr_url"],
        interview: interview,
        answers: answered(interview),
        show_answers?: current_id in [Setup.step_id(:interview), Setup.step_id(:customize)],
        asking?: current_id == Setup.step_id(:interview),
        changes: if(current_id == Setup.step_id(:customize), do: List.wrap(customize.data["changes"]), else: [])
      )

    ~H"""
    <div
      :if={@pr_url}
      id={"#{@prefix}-onboard-pr"}
      class="flex flex-col gap-1 rounded-lg p-2.5"
      style="background:color-mix(in oklab, var(--color-secondary) 7%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-secondary) 35%, var(--color-base-100))"
    >
      <span style="font-size:12px;font-weight:600">Waiting for your PR to merge</span>
      <span style={"font-size:11.5px;" <> muted()}>
        The runner can't work until these files are on origin/{@current.data["base"]}.
        <a
          id={"#{@prefix}-onboard-pr-link"}
          href={@pr_url}
          target="_blank"
          rel="noopener noreferrer"
          class="link link-primary"
        >
          {String.replace_prefix(@pr_url, "https://", "")}
        </a>
      </span>
    </div>
    <div
      :if={@current && @current.status == :failed}
      id={"#{@prefix}-onboard-failed"}
      class="flex flex-col gap-1 rounded-lg p-2.5"
      style="background:color-mix(in oklab, var(--color-error) 7%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 40%, var(--color-base-100))"
    >
      <span style="font-size:12px;font-weight:600;color:color-mix(in oklab, var(--color-error) 65%, var(--color-base-content))">
        {@current.id} failed {times(@current.data["attempts"] || 1)}, now asking you in the terminal
      </span>
      <span :if={@current.error} class="font-mono" style={"font-size:11px;" <> muted()}>
        {@current.error}
      </span>
    </div>
    <.answers
      :if={@show_answers? and @answers != []}
      prefix={@prefix}
      answers={@answers}
      asking?={@asking?}
    />
    <.changes :if={@changes != []} prefix={@prefix} changes={@changes} />
    """
  end

  attr :prefix, :string, required: true
  attr :answers, :list, required: true, doc: "`[{question, answer}]` in catalog order"
  attr :asking?, :boolean, required: true, doc: "5.3 is still current: the next question is out"

  defp answers(assigns) do
    assigns = assign(assigns, total: length(Setup.interview_questions()), count: length(assigns.answers))

    ~H"""
    <details
      id={"#{@prefix}-answers"}
      open
      class="flex flex-col gap-1 rounded-lg border border-base-300 bg-base-100 px-3 py-2"
    >
      <summary
        class="flex cursor-pointer list-none items-center gap-1.5"
        style="font-size:12px;font-weight:600"
      >
        <span class="font-mono" style={"font-size:10px;" <> faint()}>▾</span>
        Your answers
        <span
          id={"#{@prefix}-answers-count"}
          class="font-mono"
          style={"font-size:10.5px;font-weight:400;" <> muted()}
        >
          {@count} of {@total}
        </span>
      </summary>
      <div class="mt-1 flex flex-col gap-1">
        <div
          :for={{question, answer} <- @answers}
          id={"#{@prefix}-answer-#{question.id}"}
          class="grid gap-2"
          style="grid-template-columns:96px minmax(0,1fr);font-size:12px"
        >
          <span style={muted()}>{question.label}</span>
          <span class="truncate" style="font-weight:500">{answer}</span>
        </div>
        <div
          :if={@asking? and @count < @total}
          id={"#{@prefix}-question-next"}
          class="flex items-center gap-1.5 font-mono"
          style="font-size:10.5px;color:color-mix(in oklab, var(--color-secondary) 75%, var(--color-base-content))"
        >
          <span
            class="animate-pulse"
            style="width:6px;height:6px;border-radius:50%;background:currentColor;display:inline-block"
          >
          </span>
          question {@count + 1} of {@total} in your terminal…
        </div>
        <div id={"#{@prefix}-project-md"} class="font-mono" style={"font-size:10.5px;" <> faint()}>
          → .relay/project.md (committed in 5.6) · copy kept on the board
        </div>
      </div>
    </details>
    """
  end

  attr :prefix, :string, required: true
  attr :changes, :list, required: true, doc: ~S(5.4's `data["changes"]`)

  defp changes(assigns) do
    rows =
      for {change, i} <- Enum.with_index(assigns.changes, 1) do
        {glyph, label, color} = decision_marker(change)

        %{
          i: i,
          decision: change["decision"],
          glyph: glyph,
          label: label,
          color: color,
          faint?: glyph == pending_glyph(),
          segments: code_segments(change["summary"])
        }
      end

    assigns = assign(assigns, rows: rows)

    ~H"""
    <div
      id={"#{@prefix}-changes"}
      class="flex flex-col gap-1.5 rounded-lg px-3 py-2"
      style="background:color-mix(in oklab, var(--color-secondary) 6%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-secondary) 35%, var(--color-base-100))"
    >
      <div id={"#{@prefix}-changes-header"} style="font-size:12px;font-weight:600">
        {length(@changes)} proposed changes · agreeing one at a time
      </div>
      <div
        :for={row <- @rows}
        id={"#{@prefix}-change-#{row.i}"}
        data-decision={row.decision}
        class="flex items-start gap-2"
        style="font-size:12px"
      >
        <span class="setup-change-glyph font-mono" style={"width:12px;font-weight:700;" <> row.color}>
          {row.glyph}
        </span>
        <span
          class="setup-change-summary min-w-0 flex-1"
          style={if(row.faint?, do: faint(), else: "")}
        >
          <%= for {kind, text} <- row.segments do %>
            <%= if kind == :code do %>
              <code class="font-mono">{text}</code>
            <% else %>
              {text}
            <% end %>
          <% end %>
        </span>
        <span class="setup-change-label flex-none font-mono" style={"font-size:10.5px;" <> row.color}>
          {row.label}
        </span>
      </div>
      <div id={"#{@prefix}-changes-note"} class="font-mono" style={"font-size:10.5px;" <> muted()}>
        Nothing is changed until all {length(@changes)} are decided. Then only the accepted ones are applied.
      </div>
    </div>
    """
  end

  # 5.3's answers as `[{question, answer}]`, in catalog order, unanswered questions left out.
  defp answered(nil), do: []

  defp answered(interview) do
    answers = interview.data["answers"] || %{}

    for question <- Setup.interview_questions(),
        answer = answers[question.id],
        is_binary(answer) and String.trim(answer) != "",
        do: {question, answer}
  end

  # Whole minutes since step 5 was reached, at least 1.
  defp elapsed_minutes(reached_at, now), do: max(div(DateTime.diff(now, reached_at), 60), 1)

  defp times(1), do: "1 time"
  defp times(n), do: "#{n} times"

  # A change summary split on backticks: odd segments are code. With an odd number of backticks
  # the last one has no partner and stays literal text.
  defp code_segments(summary) do
    parts = String.split(to_string(summary), "`")
    last = length(parts) - 1
    paired? = rem(length(parts), 2) == 1

    parts
    |> Enum.with_index()
    |> Enum.map(fn
      {text, ^last} when not paired? -> {:text, "`" <> text}
      {text, i} when rem(i, 2) == 1 -> {:code, text}
      {text, _i} -> {:text, text}
    end)
  end

  # A 5.4 change's `{glyph, label, colour style}` by its `"decision"` (`Setup.change_decisions/0`).
  defp decision_marker(%{"decision" => "accepted"}), do: {"✓", "accepted", tone_70("success")}
  defp decision_marker(%{"decision" => "rejected"}), do: {"✕", "rejected", tone_70("error")}
  defp decision_marker(%{"decision" => "edited"} = change), do: {"✎", change["note"], tone_70("primary")}
  defp decision_marker(%{"decision" => "asking"}), do: {"▸", "asking you now", tone_70("secondary")}
  defp decision_marker(_pending), do: {pending_glyph(), "", @faint}

  defp pending_glyph, do: "○"

  defp skipped_glyph, do: "–"

  # A connect leaves out the sub-steps a machine never runs (`Setup.connect_skips/0`); a board's
  # checklist shows all of them.
  defp visible_children(children, true = _connect?), do: Enum.reject(children, &(&1.id in Setup.connect_skips()))
  defp visible_children(children, false), do: children

  defp substep_glyph(:done), do: "✓"
  defp substep_glyph(:active), do: "▸"
  defp substep_glyph(:waiting), do: "◌"
  defp substep_glyph(:failed), do: "!"
  defp substep_glyph(:skipped), do: skipped_glyph()
  defp substep_glyph(:pending), do: pending_glyph()

  defp substep_color(:done), do: tone_70("success")
  defp substep_color(:failed), do: tone_70("error")
  defp substep_color(status) when status in [:active, :waiting], do: tone_70("secondary")
  defp substep_color(_pending_or_skipped), do: @faint

  defp tone_70(tone), do: "color:color-mix(in oklab, var(--color-#{tone}) 70%, var(--color-base-content))"

  # ---------------------------------------------------------------- steps 2–4

  attr :prefix, :string, required: true
  attr :selected, :string, required: true

  attr :current, :string,
    default: nil,
    doc: "the board's default harness in a finished step 2's peek (RE456): badges its row and offers a switch"

  defp llm_picker(assigns) do
    llms = Setup.onboarding_llms()

    selected =
      Enum.find(llms, &(&1.harness == assigns.selected)) || Enum.find(llms, &(&1.harness == assigns.current)) ||
        Enum.find(llms, & &1.recommended?)

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
            <span
              :if={@current == llm.harness}
              id={"#{@prefix}-llm-#{llm.harness}-current"}
              class="badge badge-ghost badge-xs"
            >
              current
            </span>
          </span>
          <span style={"font-size:11.5px;" <> muted()}>{llm.blurb}</span>
        </span>
      </label>
    </.form>
    <button
      :if={is_nil(@current)}
      type="button"
      id={"#{@prefix}-use-llm"}
      phx-click="setup_choose_llm"
      phx-value-llm={@selected.harness}
      class="btn btn-primary btn-sm self-start"
    >
      Use {@selected.label}
    </button>
    <%= if @current do %>
      <button
        type="button"
        id={"#{@prefix}-switch-llm"}
        phx-click="setup_switch_llm"
        phx-value-llm={@selected.harness}
        disabled={@selected.harness == @current}
        class={
          if(@selected.harness == @current,
            do: "btn btn-sm self-start",
            else: "btn btn-primary btn-sm self-start"
          )
        }
      >
        {if(@selected.harness == @current,
          do: "#{@selected.label} is the default",
          else: "Switch to #{@selected.label}"
        )}
      </button>
      <div style={"font-size:11.5px;" <> muted()}>
        The step stays done; its title follows the new default.
      </div>
    <% end %>
    """
  end

  attr :prefix, :string, required: true
  attr :token, :string, required: true
  attr :unsaved, :boolean, default: false, doc: "an unsaved connect: nothing minted yet"
  attr :saved_button, :boolean, default: true, doc: ~s(the "I've saved it — next" button; a peek has none)

  defp key_box(%{token: nil, unsaved: true} = assigns) do
    ~H"""
    <button
      type="button"
      id={"#{@prefix}-mint-key"}
      phx-click="setup_mint_key"
      class="btn btn-primary btn-sm self-start"
    >
      Mint my key
    </button>
    """
  end

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
        1Password. Hamaca never writes it to disk.
      </div>
    </div>
    <button
      :if={@saved_button}
      type="button"
      id={"#{@prefix}-key-saved"}
      phx-click="setup_key_saved"
      class="btn btn-primary btn-sm self-start"
    >
      I've saved it — next
    </button>
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
    <.install_command prefix={@prefix} install_command={@install_command} />
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
        in the same folder and run <code class="font-mono">{onboard_command()}</code>.
      </span>
    </div>
    """
  end

  # Step 4's install command and where to run it: the current step's and its peek's.
  attr :prefix, :string, required: true
  attr :install_command, :string, required: true

  defp install_command(assigns) do
    ~H"""
    <.code_row
      :if={@install_command}
      id={"#{@prefix}-install-command"}
      text={@install_command}
      label="Copy install command"
    />
    <div style={"font-size:11.5px;" <> muted()}>
      Run it at the root of your repo. It checks first, then tells you everything it's about to write.
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
  attr :now, DateTime, default: nil, doc: "the clock step 5's elapsed time reads; nil is `DateTime.utc_now/0`"
  attr :user_name, :string, default: nil, doc: "who is signed in (name or email), for a connect's member note"
  attr :peeks, MapSet, default: MapSet.new(), doc: "the top-level step ids whose peek is open (RE456)"

  def setup_panel(assigns) do
    assigns =
      assign(assigns,
        prefix: @panel_prefix,
        progress: round(assigns.checklist.done_count * 100 / assigns.checklist.total),
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
            {@checklist.position} of {@checklist.total}
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
        <h2 class="font-semibold tracking-tight" style="font-size:18px">
          {if(@checklist.connect?,
            do: "Connect a machine to #{@board_name}",
            else: "Set up #{@board_name}"
          )}
        </h2>
        <.member_note
          :if={@checklist.connect?}
          id={"#{@prefix}-member-note"}
          user_name={@user_name}
          board_name={@board_name}
        />
        <progress class="progress progress-primary h-1.5 w-full" value={@progress} max="100">
        </progress>
        <label class="flex cursor-pointer items-center gap-2" style={"font-size:12px;" <> muted()}>
          <input
            type="checkbox"
            id={"#{@prefix}-explanations-toggle"}
            class="toggle toggle-xs"
            checked={@hide_explanations}
            phx-click="setup_toggle_explanations"
          /> I know Hamaca, hide explanations
        </label>
      </div>
      <div class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-4 py-4">
        <.setup_done_box :if={@checklist.finished?} id={"#{@prefix}-done"} checklist={@checklist} />
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
          now={@now}
          peeks={@peeks}
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
  attr :user_name, :string, required: true
  attr :board_name, :string, required: true

  # A connect's "whose key is this" note (frame D): the key and the runner are the signed-in person's.
  defp member_note(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex items-start gap-2 rounded-lg bg-base-200 px-2.5 py-2"
      style="font-size:11.5px"
    >
      <span
        class="font-mono"
        style="font-size:9px;font-weight:700;width:20px;height:20px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;flex:0 0 auto;background:var(--color-primary);color:var(--color-primary-content)"
      >
        {initials(@user_name)}
      </span>
      <span>
        Signed in as <b>{@user_name}</b>, a member of {@board_name}. The key this mints is {@user_name}'s, and so is the runner.
        <span style={muted()}>Not a member? Ask an owner to add you in Members first.</span>
      </span>
    </div>
    """
  end

  # The first letters of the first two words, or the first two letters of a one-word name, upcased.
  defp initials(nil), do: "?"

  defp initials(name) do
    case_result =
      case String.split(name) do
        [first, second | _rest] -> String.first(first) <> String.first(second)
        [one] -> String.slice(one, 0, 2)
        [] -> "?"
      end

    String.upcase(case_result)
  end

  # ---------------------------------------------------------------- Board settings → Setup

  @doc """
  The one-line state of a board's setup for Board settings → Setup:
  `"Finished 12 Oct, 14:42 · 7 of 7 · 40 min"` once finished, else `"In progress · 4 of 7"`.
  """
  @spec status_line(map()) :: String.t()
  def status_line(%{finished?: true, finished_at: %DateTime{} = at, total: total} = checklist) do
    Enum.join(
      [
        "Finished #{Calendar.strftime(at, "%-d %b, %H:%M")}",
        "#{total} of #{total}" | List.wrap(minutes(checklist.elapsed_minutes, :short))
      ],
      " · "
    )
  end

  def status_line(%{position: position, total: total}), do: "In progress · #{position} of #{total}"

  attr :id, :string, required: true
  attr :answers, :list, required: true, doc: "`Relay.Setup.project_answers/1`: `[%{id, label, answer}]`"

  @doc """
  The onboarding answers (5.3) for Board settings → Setup (frame C): a two-column label/answer grid,
  or "No answers yet" when there are none, and a footnote saying where to change them.
  """
  def project_answers(assigns) do
    assigns = assign(assigns, interview: Setup.step_id(:interview))

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <div class="flex items-baseline gap-2">
        <span style="font-size:13.5px;font-weight:600">Project answers</span>
        <span class="font-mono" style={"font-size:10.5px;" <> muted()}>
          from onboarding · also in .relay/project.md
        </span>
      </div>
      <div
        :if={@answers != []}
        class="grid gap-x-6 gap-y-1 rounded-lg border border-base-300 p-3"
        style="grid-template-columns:repeat(2,minmax(0,1fr))"
      >
        <div
          :for={answer <- @answers}
          id={"#{@id}-#{answer.id}"}
          class="grid gap-2"
          style="grid-template-columns:96px minmax(0,1fr);font-size:12px"
        >
          <span style={muted()}>{answer.label}</span>
          <span class="truncate" style="font-weight:500">{answer.answer}</span>
        </div>
      </div>
      <p
        :if={@answers == []}
        class="rounded-lg border border-base-300 p-3"
        style={"font-size:12px;" <> muted()}
      >
        No answers yet. Onboarding records them in step {@interview}.
      </p>
      <p id={"#{@id}-footnote"} style={"font-size:11.5px;" <> muted()}>
        A copy for reference. To change one, edit .relay/project.md in the repo; the next onboard run reports it here.
      </p>
    </div>
    """
  end

  attr :id, :string, required: true, doc: "the table's DOM id; rows are `<id>-board` and `<id>-<machine id>`"
  attr :machines, :list, required: true, doc: "`Relay.Setup.machines/1`"

  @doc """
  Every setup on the board, for Board settings → Setup (frame C): Machine, Person, Key (`…last4`),
  Harnesses (`claude ✓`) and the Setup badge (success once finished, else primary). An empty cell
  reads a faint `—`.
  """
  def setup_machines_table(assigns) do
    ~H"""
    <table id={@id} class="table table-sm">
      <thead>
        <tr>
          <th>Machine</th>
          <th>Person</th>
          <th>Key</th>
          <th>Harnesses</th>
          <th>Setup</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @machines} id={"#{@id}-#{row.id}"}>
          <td class="font-medium"><.cell value={row.machine} /></td>
          <td><.cell value={row.person} /></td>
          <td class="font-mono text-xs">
            <.cell value={row.key_last_four && "…#{row.key_last_four}"} />
          </td>
          <td class="font-mono text-xs"><.cell value={harnesses(row.harnesses)} /></td>
          <td>
            <span class={[
              "badge badge-sm badge-soft",
              if(row.finished?, do: "badge-success", else: "badge-primary")
            ]}>
              {if(row.finished?, do: "✓ #{row.progress}", else: row.progress)}
            </span>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :value, :string, required: true

  defp cell(%{value: nil} = assigns), do: ~H|<span style={faint()}>—</span>|
  defp cell(assigns), do: ~H|{@value}|

  defp harnesses([]), do: nil

  defp harnesses(harnesses) do
    Enum.map_join(harnesses, ", ", fn
      %{cli: cli, signed_in: true} -> "#{cli} ✓"
      %{cli: cli, signed_in: false} -> "#{cli} ✕"
      %{cli: cli} -> cli
    end)
  end

  # ---------------------------------------------------------------- payoff

  attr :id, :string, required: true
  attr :checklist, :map, required: true, doc: "a finished `Relay.Setup.checklist/1`"

  @doc """
  The "You're set up" box atop a finished panel: the minutes setup took (`elapsed_minutes`),
  then Close setup (`#setup-close`, `"setup_close"`) and Connect another machine
  (`#setup-connect-another`, `"setup_connect_another"`).
  """
  def setup_done_box(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-col gap-1.5 rounded-xl p-3"
      style="background:color-mix(in oklab, var(--color-success) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-success) 45%, var(--color-base-100))"
    >
      <span style="font-size:14px;font-weight:700;color:color-mix(in oklab, var(--color-success) 60%, var(--color-base-content))">
        You're set up.{elapsed(@checklist.elapsed_minutes)}
      </span>
      <span style={"font-size:12.5px;" <> muted()}>
        Need a command again? Open any step below; it stays done.
      </span>
      <div class="flex gap-2 pt-1">
        <button type="button" id="setup-close" phx-click="setup_close" class="btn btn-sm btn-primary">
          Close setup
        </button>
        <button
          type="button"
          id="setup-connect-another"
          phx-click="setup_connect_another"
          class="btn btn-sm btn-ghost"
        >
          ➕ Connect another machine
        </button>
      </div>
    </div>
    """
  end

  defp elapsed(nil), do: nil
  defp elapsed(minutes), do: " #{minutes(minutes, :long)}."

  # The ONE minutes format: `"40 min"` (the settings status line) or `"40 minutes"` / `"1 minute"`
  # (the done box).
  defp minutes(nil, _style), do: nil
  defp minutes(minutes, :short), do: "#{minutes} min"
  defp minutes(1, :long), do: "1 minute"
  defp minutes(minutes, :long), do: "#{minutes} minutes"

  attr :id, :string, required: true
  attr :callout, :map, required: true, doc: "the checklist's `callout`: `card_ref`, `machine`, `llm`, `verb`"

  @doc """
  The payoff callout, "An agent has the baton". Render it once, outside every stream, inside a
  `relative` box that also holds `#board`: the `.SetupCallout` hook pins it ~12px under
  `#board [data-ref=<card_ref>]` (or at 24px/24px when that card isn't on screen) and sets
  `data-setup-baton` on that card for its violet ring. The hook owns this root's `left`/`top`,
  so the root carries no server `style`.
  """
  def setup_callout(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".SetupCallout"
      data-card-ref={@callout.card_ref}
      class="absolute z-30"
      role="status"
    >
      <div
        class="relative flex flex-col gap-2 rounded-xl bg-base-100 p-3.5"
        style="width:300px;border:1px solid color-mix(in oklab, var(--color-secondary) 55%, var(--color-base-100));box-shadow:0 10px 30px color-mix(in oklab, var(--color-neutral) 18%, transparent)"
      >
        <span
          class="absolute"
          aria-hidden="true"
          style="left:40px;top:-7px;width:12px;height:12px;background:var(--color-base-100);transform:rotate(45deg);border-left:1px solid color-mix(in oklab, var(--color-secondary) 55%, var(--color-base-100));border-top:1px solid color-mix(in oklab, var(--color-secondary) 55%, var(--color-base-100))"
        >
        </span>
        <div class="flex items-center gap-2">
          <span
            class="font-mono"
            style="font-size:9px;font-weight:700;width:20px;height:20px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;flex:0 0 auto;background:var(--color-secondary);color:var(--color-secondary-content)"
          >
            AI
          </span>
          <span style="font-size:13.5px;font-weight:700">An agent has the baton</span>
        </div>
        <p style="font-size:12.5px;line-height:1.5">
          {@callout.card_ref} just turned <b style="color:color-mix(in oklab, var(--color-secondary) 80%, var(--color-base-content))">violet</b>: your runner on {@callout.machine} claimed it and {@callout.llm} is {@callout.verb} it now.
        </p>
        <p style="font-size:12.5px;line-height:1.5">
          When it needs you (a plan to approve, a question, a review) it comes back
          <b style="color:color-mix(in oklab, var(--color-primary) 80%, var(--color-base-content))">
            blue
          </b>
          and shows up in Needs you.
        </p>
        <div class="flex items-center gap-2 pt-1">
          <button
            type="button"
            id={"#{@id}-watch"}
            phx-click="setup_callout_watch"
            class="btn btn-secondary btn-sm"
          >
            Watch it work
          </button>
          <button
            type="button"
            id={"#{@id}-dismiss"}
            phx-click="setup_close"
            class="btn btn-ghost btn-sm"
          >
            Got it
          </button>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SetupCallout">
      // RE446 — pins the payoff callout ~12px under the claimed card, its arrow over the card's
      // left part, and rings that card (data-setup-baton, styled in app.css). Cards are stream
      // items that a re-insert replaces, so a MutationObserver on #board re-applies the ring;
      // updated() and resize/scroll re-apply the position. The fallback (card filtered, paged
      // away, or not rendered) is 24px/24px.
      const GAP = 12
      const FALLBACK = 24

      export default {
        mounted() {
          this.board = document.getElementById("board")
          this.place = () => this.apply()
          window.addEventListener("resize", this.place)
          if (this.board) {
            this.board.addEventListener("scroll", this.place, {capture: true, passive: true})
            this.mutations = new MutationObserver(this.place)
            this.mutations.observe(this.board, {childList: true, subtree: true})
          }
          this.apply()
        },
        updated() { this.apply() },
        destroyed() {
          window.removeEventListener("resize", this.place)
          if (this.board) this.board.removeEventListener("scroll", this.place, {capture: true})
          if (this.mutations) this.mutations.disconnect()
          this.unring()
        },
        card() {
          if (!this.board) return null
          return this.board.querySelector(`[data-ref="${CSS.escape(this.el.dataset.cardRef)}"]`)
        },
        unring(keep) {
          document.querySelectorAll("[data-setup-baton]").forEach(el => {
            if (el !== keep) el.removeAttribute("data-setup-baton")
          })
        },
        apply() {
          const card = this.card()
          this.unring(card)
          const box = this.el.offsetParent
          if (!card || !box || card.getClientRects().length === 0) {
            this.el.style.left = `${FALLBACK}px`
            this.el.style.top = `${FALLBACK}px`
            return
          }
          if (!card.hasAttribute("data-setup-baton")) card.setAttribute("data-setup-baton", "")
          const c = card.getBoundingClientRect()
          const b = box.getBoundingClientRect()
          this.el.style.left = `${Math.round(c.left - b.left)}px`
          this.el.style.top = `${Math.round(c.bottom - b.top + GAP)}px`
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true

  def how_relay_works(assigns) do
    ~H"""
    <details id={@id} open class="rounded-xl border border-base-300 bg-base-100 p-3">
      <summary class="cursor-pointer list-none" style="font-size:12px;font-weight:600">
        <span class="font-mono" style={"font-size:10px;" <> faint()}>▾</span> How Hamaca works
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
        label: chip_label(assigns.checklist),
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

  defp chip_label(%{finished?: true}), do: "Setup · done"
  defp chip_label(%{position: position, total: total}), do: "Setup · #{position} of #{total}"

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

  # A skipped step on a connect (frame D): a dashed faint circle around `–`.
  defp connect_skipped_marker, do: @marker <> "border:1.5px dashed var(--color-base-300);" <> @faint

  defp marker_glyph(%{status: :done}), do: "✓"
  defp marker_glyph(%{status: :failed}), do: "!"
  defp marker_glyph(%{id: id}), do: id

  @title "font-size:13.5px;font-weight:600;letter-spacing:-0.01em;"

  defp title_style(:pending), do: @title <> @faint
  defp title_style(:skipped), do: @title <> @faint
  defp title_style(_status), do: @title

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
