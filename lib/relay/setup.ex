defmodule Relay.Setup do
  @moduledoc """
  The Setup context (RE443): a board's **setup checklist** — the guided path from "board created
  from a template" to "an agent picked up the first card".

  This module owns the step **catalog** (`steps/0`), the ONE list of step ids, titles, actors,
  *why* and *what this does* lines; every surface renders from it through `checklist/1`, the only
  place the `%{template}`, `%{llm}`, `%{cli}`, `%{skill_dir}`, `%{skill_path}` and `%{pointer_file}` placeholders
  resolve. It also owns the onboarding LLMs (`onboarding_llms/0`) step 2 offers.

  Storage is one `Schemas.BoardSetupStep` row per `(board, catalog id)`, inserted by `start/2`
  from `Relay.Boards.create_board/2` on the template path only — a board with no rows has no
  checklist. `advance/4` moves it strictly in order: only the **reportable** step
  (`reportable_id/1`) may change — the current sub-step (`current_sub_id`, the first unfinished
  child of the current top-level step) when that step has children, else the current top-level
  step (the first not in `Schemas.BoardSetupStep.finished_statuses/0`). A parent with children is
  never advanced directly: activating it activates its first child, finishing a child activates
  the next, and finishing the last child finishes the parent (`"onboarded HH:MM"`) and activates
  the next top-level step. Every change broadcasts `{:setup_changed, board_id}` through
  `Relay.Events.broadcast/2`.

  Step 5's sub-steps (RE445) are reported by the `/relay-onboard` skill through
  `GET /api/setup` / `POST /api/setup/steps/:step`; `interview_questions/0` (5.3) and
  `change_decisions/0` (5.4) are the closed sets their `data` uses. Two are also **board-observed**:
  `Relay.Flows` calls `observe_flow_push/2` after a committed flow push (5.5 finishes once every
  board flow has been pushed and is enabled) and `Relay.Cards` calls `observe_card_created/1`
  after a committed create (5.8 finishes on a card in `first_flow_stage`, the top-level stage
  with the lowest position that holds a flow). Both are no-ops unless that sub-step is current.

  Steps 6 and 7 (RE446) are board-observed too: the runner heartbeat calls `observe_heartbeat/2`
  (step 6, the machine and its harness sign-in) and `Relay.Runs.claim_next_job/4` calls
  `observe_claim/2` after its commit (step 7, the payoff: the claimed card's facts land in step 7's
  `data`). `close/1` / `reopen/1` store the payoff state (`callout_dismissed_at`, `closed_at`) on
  step 7, which the checklist exposes as `closed?` and `callout`.

  `choose_llm/3` (step 2) sets the board's default agent and mints the step-3 board key;
  `remint_key/2` replaces it. The raw token is returned to the caller once and never stored.
  `key_saved/1` (RE455) finishes step 3 on the user's say-so, saved but not yet confirmed;
  `key_unconfirmed?/1` says when that is still so, and `remint_key/2` then reopens step 3.

  The install handshake (`GET /b/:slug/install`) reports through `preflight/2` and `installed/2`:
  the key's first authed call ticks step 3 — or confirms a saved one, in the same transaction —
  the preflight result marks step 4 waiting or failed (with the fix text from
  `preflight_checks/0`'s catalog), and the written files finish step 4.

  `list_for_admin/1` derives one progress row per checklist board (current step, time on it,
  total time, last evidence or error, stuck after `stuck_after/0`) from one query, for the
  superadmin `/admin/onboarding` page (RE448).

  `Relay.Boards`, `Relay.Flows` and `Relay.Cards` depend on this context, so this one never calls
  them: it counts stages, flows and cards with `Relay.Repo` queries.
  """

  use Boundary, deps: [Relay.Agents, Relay.ApiKeys, Relay.Events, Relay.Repo, Relay.Scaffold, Schemas]

  import Ecto.Query

  alias Relay.Agents
  alias Relay.ApiKeys
  alias Relay.Events
  alias Relay.Repo
  alias Relay.Scaffold
  alias Schemas.ApiKey
  alias Schemas.Board
  alias Schemas.BoardSetupStep
  alias Schemas.Card
  alias Schemas.Flow
  alias Schemas.NodeJob
  alias Schemas.Runner
  alias Schemas.SetupMachine
  alias Schemas.Stage
  alias Schemas.User

  @type actor :: :you_here | :you_terminal | :ai_terminal

  @type step :: %{
          id: String.t(),
          parent: String.t() | nil,
          title: String.t(),
          done_title: String.t() | nil,
          actor: actor(),
          why: String.t() | nil,
          what_this_does: [String.t()],
          read_only_note: String.t() | nil,
          connect_title: String.t() | nil,
          connect_why: String.t() | nil,
          short: String.t()
        }

  @type llm :: %{
          harness: String.t(),
          label: String.t(),
          cli: String.t(),
          blurb: String.t(),
          install: String.t() | nil,
          skill_dir: String.t() | nil,
          skill_path: String.t() | nil,
          pointer_file: String.t() | nil,
          recommended?: boolean(),
          enabled?: boolean()
        }

  @type entry :: %{
          id: String.t(),
          parent: String.t() | nil,
          title: String.t(),
          done_title: String.t() | nil,
          actor: actor(),
          why: String.t() | nil,
          what_this_does: [String.t()],
          read_only_note: String.t() | nil,
          connect_title: String.t() | nil,
          connect_why: String.t() | nil,
          short: String.t(),
          status: BoardSetupStep.status(),
          reached_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          evidence: String.t() | nil,
          error: String.t() | nil,
          data: map(),
          children: [entry()]
        }

  @type checklist :: %{
          board_id: integer() | nil,
          connect?: boolean(),
          machine_id: integer() | nil,
          template: String.t(),
          template_warning: String.t() | nil,
          llm: llm(),
          current_id: String.t() | nil,
          current_sub_id: String.t() | nil,
          first_flow_stage: String.t() | nil,
          position: 1..7,
          done_count: 0..7,
          finished?: boolean(),
          total: pos_integer(),
          closed?: boolean(),
          callout:
            nil | %{card_ref: String.t(), card_id: integer(), machine: String.t(), llm: String.t(), verb: String.t()},
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          elapsed_minutes: non_neg_integer() | nil,
          steps: [entry()]
        }

  @type admin_state :: :in_progress | :stuck | :done

  @type admin_row :: %{
          board_id: integer(),
          name: String.t(),
          slug: String.t(),
          owner_email: String.t() | nil,
          inserted_at: DateTime.t(),
          template: String.t() | nil,
          llm: String.t() | nil,
          current: %{id: String.t(), title: String.t(), status: BoardSetupStep.status(), actor: actor()},
          on_step: non_neg_integer() | nil,
          total: non_neg_integer() | nil,
          last: %{kind: :evidence | :error, text: String.t()} | nil,
          stuck?: boolean(),
          state: admin_state(),
          checklist: checklist()
        }

  @actors [:you_here, :you_terminal, :ai_terminal]

  # A board on the same step for longer than this many seconds (2h) is stuck.
  @stuck_after 2 * 60 * 60

  @admin_states [:in_progress, :stuck, :done]

  @step_blank %{
    parent: nil,
    done_title: nil,
    why: nil,
    what_this_does: [],
    read_only_note: nil,
    connect_title: nil,
    connect_why: nil
  }

  @onboard_children [
    {"5.1", "Pull flows into .relay/flows/"},
    {"5.2", "Detect & confirm repo facts"},
    {"5.3", "Interview → .relay/project.md"},
    {"5.4", "Customize: propose, agree 1 by 1, apply"},
    {"5.5", "Push flows back (enabled on arrival)"},
    {"5.6", "Relay files on origin/main"},
    {"5.7", "Follow-up cards #setup"},
    {"5.8", "First card"}
  ]

  # The ONE step catalog, in catalog order 1, 2, 3, 4, 5, 5.1 … 5.8, 6, 7.
  @steps Enum.map(
           [
             %{
               id: "1",
               title: "Board created",
               done_title: "Board created from %{template}",
               connect_title: "Board: %{board}",
               short: "board",
               actor: :you_here,
               why: "Your stages and flows, from the template. No cards yet.",
               what_this_does: [
                 "Created this board's stages and flows from the %{template} template. Nothing is on your machine yet."
               ]
             },
             %{
               id: "2",
               title: "Pick your default LLM",
               done_title: "Default LLM: %{llm}",
               connect_title: "Default LLM: %{llm}",
               short: "llm",
               actor: :you_here,
               why: "Flows run on this CLI unless a node says otherwise.",
               what_this_does: [
                 "Sets this board's default agent: every flow node that doesn't name its own LLM runs on it.",
                 "Change it later in Board settings → Agents. Nothing is installed yet."
               ]
             },
             %{
               id: "3",
               title: "Add your key to your environment",
               done_title: "Key in your environment",
               connect_title: "Your key for this machine",
               short: "key",
               actor: :you_here,
               why: "The runner proves it's allowed to work this board with this key.",
               what_this_does: [
                 "Mints a board key in your name; Board settings → API keys lists it.",
                 "The board keeps only a hash, so the key is shown once, here.",
                 "Export it as RELAY_API_KEY: the install script and ./relay read it from your environment."
               ],
               read_only_note: "Needs a computer: the key goes into the shell where your repo lives."
             },
             %{
               id: "4",
               title: "Install in your repo",
               connect_title: "Install on this machine",
               short: "install",
               actor: :you_terminal,
               why: "Puts the runner and the Relay skills in your repo. It's a script you run, not a file you set up.",
               what_this_does: [
                 "./relay — the runner and CLI, with this board's URL baked in",
                 "%{skill_dir}/relay-onboard, relay-update and relay-doctor — the Relay skills",
                 "relay.md, plus one line in %{pointer_file} pointing at it",
                 ".relay/runner.json — runner settings, base set to your default branch (kept if present)",
                 ".relay/prepare-worktree.sh — the warm-up hook, empty until onboarding fills it (kept if present)",
                 ".gitignore — .claude/worktrees/, /tmp/ and .envrc.local, each added once",
                 "Nothing is committed; onboarding does that with you."
               ]
             },
             %{
               id: "5",
               title: "Onboard, in %{llm}",
               connect_title: "Onboard, pull only",
               short: "onboard",
               actor: :ai_terminal,
               why:
                 "Open %{cli} in your repo and run /relay-onboard. It works this list until it's green and asks you in the chat when it's stuck.",
               what_this_does: ["Run /relay-onboard in your repo; it works sub-steps 5.1–5.8 below."],
               connect_why:
                 "Pulls the board's flows and checks the Relay files are already on origin/main. No interview, no customizing."
             }
           ] ++
             Enum.map(@onboard_children, fn {id, title} ->
               %{id: id, parent: "5", title: title, short: title, actor: :ai_terminal}
             end) ++
             [
               %{
                 id: "6",
                 title: "Start the runner",
                 done_title: "Runner online",
                 short: "runner",
                 actor: :you_terminal,
                 why: "The runner is what actually picks up cards. Give it its own terminal and leave it running.",
                 what_this_does: ["Run ./relay start in its own terminal. This ticks on the runner's first heartbeat."]
               },
               %{
                 id: "7",
                 title: "Watch an agent pick up your first card",
                 done_title: "First card claimed",
                 connect_title: "First card",
                 short: "first card",
                 actor: :you_here,
                 why: "Setup is done when the runner claims a real card, not before.",
                 what_this_does: [
                   "Ticks when the runner claims your first card. The card turns violet while an agent holds the baton."
                 ]
               }
             ],
           &Map.merge(@step_blank, &1)
         )

  @top_ids for step <- @steps, is_nil(step.parent), do: step.id

  # Each parent's children ids, in catalog order.
  @child_ids @steps |> Enum.filter(& &1.parent) |> Enum.group_by(& &1.parent, & &1.id)

  # Every step a report can move, in the order the checklist walks them: a parent with children
  # is replaced by its children (1, 2, 3, 4, 5.1 … 5.8, 6, 7).
  @walk_ids Enum.flat_map(@top_ids, &Map.get(@child_ids, &1, [&1]))

  # The steps this context drives itself: step 1 (start), step 2 (choose_llm), step 3 (the key),
  # step 4 (the install handshake).
  @created_step Enum.at(@top_ids, 0)
  @llm_step Enum.at(@top_ids, 1)
  @key_step Enum.at(@top_ids, 2)
  @install_step Enum.at(@top_ids, 3)
  @onboard_step Enum.at(@top_ids, 4)

  # The two top-level steps the board observes itself (RE446): 6 (the runner's first heartbeat)
  # and 7 (the first node-job claim, the payoff).
  @runner_step Enum.at(@top_ids, 5)
  @claim_step Enum.at(@top_ids, 6)

  # The verb the payoff callout uses for the claimed card's stage category, read at claim time.
  @claim_verbs %{planning: "planning", in_progress: "building"}
  @claim_verb_default "working on"

  # The sub-steps the board observes itself: 5.5 (flows pushed back) and 5.8 (the first card).
  @interview_step @onboard_children |> Enum.at(2) |> elem(0)
  @customize_step @onboard_children |> Enum.at(3) |> elem(0)
  @push_step @onboard_children |> Enum.at(4) |> elem(0)
  @first_card_step @onboard_children |> Enum.at(7) |> elem(0)

  # What a connected machine (RE446) skips: the board-wide steps (1, 2 and 7) and every onboard
  # sub-step but 5.1 (pull the flows) and 5.6 (the Relay files are on origin/main).
  @pull_step @onboard_children |> Enum.at(0) |> elem(0)
  @files_step @onboard_children |> Enum.at(5) |> elem(0)
  @connect_skips [@created_step, @llm_step] ++
                   for({id, _title} <- @onboard_children, id not in [@pull_step, @files_step], do: id) ++
                   [@claim_step]

  # The skipped board-wide steps' evidence on a connect; step 7's is read from the board at build time.
  @connect_evidence %{@created_step => "already set up", @llm_step => "board-wide · already chosen"}

  # The ONE 5.3 interview catalog, in the order the skill asks it.
  @interview_questions [
    %{id: "done", label: "Done means", question: ~s(What does "done" mean for a card: a PR opened, merged, or deployed?)},
    %{
      id: "landing",
      label: "Changes land",
      question: "How do changes land: a PR you merge, or a push straight to the base branch?"
    },
    %{
      id: "deploy",
      label: "Deploy",
      question: "How do you deploy, and does Relay ever do it (by default Deploy stays human)?"
    },
    %{id: "baton", label: "Baton back", question: "Where does the baton come back to you?"},
    %{
      id: "ui",
      label: "UI",
      question: "Is there a UI, and how do you run it (no UI drops the screenshot and smoke nodes)?"
    },
    %{id: "never_touch", label: "Never touch", question: "Which paths must an agent never touch?"},
    %{
      id: "warm_up",
      label: "Warm-up",
      question: "Which build or dependency directories should a fresh checkout warm up?"
    },
    %{
      id: "capacity",
      label: "Capacity",
      question: "How many cards at once, and how much of your LLM plan may Relay use?"
    },
    %{id: "misfits", label: "Misfits", question: "Is there anything in the template that doesn't fit how you work?"}
  ]

  # The ONE set of 5.4 per-change markers.
  @change_decisions ["pending", "asking", "accepted", "rejected", "edited"]

  # The ONE set of 5.4's missing-file resolutions (RE447): a copied board's flows can name
  # `.claude/` files the repo lacks, and 5.4 resolves each one before the regular proposals.
  @missing_file_resolutions ["stub", "inline", "drop", "path"]

  @nothing_written "run the same command again. Nothing was written."

  # The ONE list of the install script's local checks, in print order, with each one's fix text.
  # `preflight_checks/0` exposes the ids and labels; the script bakes them in at render time.
  @preflight_checks [
    %{
      id: "git_repo",
      label: "git repo",
      headline: "Preflight stopped: this isn't the top of a git repo",
      fix: "Run it from your repo's top folder (the one with .git in it), then #{@nothing_written}",
      fix_command: nil
    },
    %{
      id: "remote",
      label: "remote",
      headline: "Preflight stopped: your repo has no origin remote",
      fix: "Add one with `git remote add origin <url>`, then #{@nothing_written}",
      fix_command: "git remote add origin <url>"
    },
    %{
      id: "default_branch",
      label: "default branch",
      headline: "Preflight stopped: couldn't tell your default branch",
      fix: "Point origin/HEAD at it with `git remote set-head origin --auto`, then #{@nothing_written}",
      fix_command: "git remote set-head origin --auto"
    },
    %{
      id: "python3",
      label: "python3",
      headline: "Preflight stopped: python3 isn't on your PATH",
      fix: "./relay runs on Python 3. Install it, open a new terminal, and #{@nothing_written}",
      fix_command: nil
    }
  ]

  @preflight_ids Enum.map(@preflight_checks, & &1.id)

  @advance_statuses [:waiting, :done, :failed, :skipped]

  # Onboarding facts per harness key; `harness` and `label` come from `Agents.seed_harnesses/0`.
  # This map is the only place the per-CLI skill directory and pointer file are written;
  # `skill_path` is derived from `skill_dir` by `onboarding_llms/0`, never stored here.
  @llm_facts %{
    "claude-code" => %{
      cli: "claude",
      blurb: "Recommended. Best tested with Relay's flows.",
      install: "npm install -g @anthropic-ai/claude-code",
      skill_dir: Scaffold.skill_dir(),
      pointer_file: "CLAUDE.md",
      recommended?: true,
      enabled?: true
    },
    "codex" => %{
      cli: "codex",
      blurb: "OpenAI's CLI.",
      install: "npm install -g @openai/codex",
      skill_dir: ".agents/skills",
      pointer_file: "AGENTS.md",
      recommended?: false,
      enabled?: true
    },
    "gemini-cli" => %{
      cli: "gemini",
      blurb: "Google's CLI.",
      install: nil,
      skill_dir: nil,
      pointer_file: nil,
      recommended?: false,
      enabled?: false
    }
  }

  # ---------------------------------------------------------------- catalog

  @doc "Who moves on a step: you on this board, you in your terminal, or the AI in your terminal."
  @spec actors() :: [actor()]
  def actors, do: @actors

  @doc """
  The ONE step catalog, in order `1, 2, 3, 4, 5, 5.1 … 5.8, 6, 7`. Sub-steps carry `parent: "5"`.
  Strings may hold `%{template}`, `%{llm}`, `%{cli}`, `%{skill_dir}`, `%{skill_path}` and `%{pointer_file}`,
  resolved only by `checklist/1`.
  """
  @spec steps() :: [step()]
  def steps, do: @steps

  @doc """
  The catalog id of the step that plays `role`: `:llm` (step 2's pick), `:key` (step 3's board
  key), `:install` (step 4's install script), `:onboard` (step 5, with its sub-steps),
  `:interview` (5.3, the answers), `:customize` (5.4, the agreed changes), `:runner` (step 6, the
  runner's first heartbeat) or `:first_claim` (step 7, the first claim). Surfaces that render a
  step differently (the wizard's LLM picker, key box, install command, answers and changes
  blocks, the payoff) branch on this rather than re-typing an id.
  """
  @spec step_id(:llm | :key | :install | :onboard | :interview | :customize | :runner | :first_claim) ::
          String.t()
  def step_id(:llm), do: @llm_step
  def step_id(:key), do: @key_step
  def step_id(:install), do: @install_step
  def step_id(:onboard), do: @onboard_step
  def step_id(:interview), do: @interview_step
  def step_id(:customize), do: @customize_step
  def step_id(:runner), do: @runner_step
  def step_id(:first_claim), do: @claim_step

  @doc """
  The steps a connected machine skips, in catalog order: the board-wide steps (board, default LLM,
  first claim) and the onboard sub-steps a machine doesn't redo (detect, interview, customize,
  push back, follow-ups, first card). The ONE list; `connect_machine/2` and the connect preview
  read it.
  """
  @spec connect_skips() :: [String.t()]
  def connect_skips, do: @connect_skips

  @doc """
  The 5.3 interview, in the order it is asked: each question's `id` (the key of 5.3's
  `data["answers"]` map), its short `label` and the `question` itself.
  """
  @spec interview_questions() :: [%{id: String.t(), label: String.t(), question: String.t()}]
  def interview_questions, do: @interview_questions

  @doc ~S(The 5.4 per-change markers a `data["changes"]` entry's `"decision"` takes.)
  @spec change_decisions() :: [String.t()]
  def change_decisions, do: @change_decisions

  @doc ~S"""
  The ways 5.4 resolves a missing repo file (RE447) — a `data["missing_files"]` entry's
  `"resolution"`: write a `stub`, `inline` the prompt into the flow node, `drop` the node, or copy
  it from a local `path`.
  """
  @spec missing_file_resolutions() :: [String.t()]
  def missing_file_resolutions, do: @missing_file_resolutions

  @doc "The statuses `advance/4` (and `POST /api/setup/steps/:step`) accepts, in status order."
  @spec advance_statuses() :: [BoardSetupStep.status()]
  def advance_statuses, do: @advance_statuses

  @doc "Seconds on one step after which an unfinished checklist is stuck: 7200 (2h). The ONE threshold."
  @spec stuck_after() :: pos_integer()
  def stuck_after, do: @stuck_after

  @doc "The states an admin row is in, a partition, in filter order: in progress, stuck, done."
  @spec admin_states() :: [admin_state()]
  def admin_states, do: @admin_states

  @doc "The LLMs step 2 offers, in seed-harness order: Claude Code, Codex, Gemini CLI."
  @spec onboarding_llms() :: [llm()]
  def onboarding_llms do
    for %{key: key, name: name} <- Agents.seed_harnesses(), facts = @llm_facts[key], not is_nil(facts) do
      Map.merge(%{harness: key, label: name, skill_path: skill_path(facts.skill_dir)}, facts)
    end
  end

  defp skill_path(nil), do: nil
  defp skill_path(skill_dir), do: "#{skill_dir}/relay-onboard/SKILL.md"

  @doc "The onboarding LLM for a harness key, or nil."
  @spec onboarding_llm(String.t() | nil) :: llm() | nil
  def onboarding_llm(harness_key), do: Enum.find(onboarding_llms(), &(&1.harness == harness_key))

  @doc ~S"""
  The one line a project's pointer file (`CLAUDE.md`, `AGENTS.md`) carries to `relay.md`. The ONE
  Elixir definition; the install script renders it and the runner contract fixture pins it.
  """
  @spec pointer_line() :: String.t()
  def pointer_line, do: "Working Relay cards from this repo: see [relay.md](relay.md)."

  @doc """
  The flash a board shows when its default agent moves from harness `previous` to `next` (RE457):
  the `./relay update --skill-dir … --pointer-file …` command that moves the repo's Relay skills.
  `nil` when `next` is no onboarding LLM, has no skill dir, or keeps `previous`'s skill dir — a
  `previous` that is nil or no onboarding LLM counts as the default LLM's. The board never changes
  repo files; this only tells the human what to run.
  """
  @spec llm_switch_notice(String.t() | nil, String.t() | nil) :: String.t() | nil
  def llm_switch_notice(previous, next) do
    old = onboarding_llm(previous) || onboarding_llm(Agents.default_harness_key())

    case onboarding_llm(next) do
      %{skill_dir: dir} = llm when is_binary(dir) and dir != old.skill_dir ->
        "Your board's default LLM is now #{llm.label}. In your repo run " <>
          "./relay update --skill-dir #{dir} --pointer-file #{llm.pointer_file} and commit the result."

      _ ->
        nil
    end
  end

  @doc ~S(The step-4 install command: `"curl -fsSL <base_url>/b/<slug>/install | sh"`, base_url's trailing `/` trimmed.)
  @spec install_command(String.t(), String.t()) :: String.t()
  def install_command(base_url, slug), do: "curl -fsSL #{String.trim_trailing(base_url, "/")}/b/#{slug}/install | sh"

  @doc """
  The install script's local checks, in print order: `git_repo`, `remote`, `default_branch`,
  `python3`. The server adds the `cli` (`"<cli> on PATH"`) and `key` (`"RELAY_API_KEY"`) lines.
  """
  @spec preflight_checks() :: [%{id: String.t(), label: String.t()}]
  def preflight_checks, do: Enum.map(@preflight_checks, &Map.take(&1, [:id, :label]))

  @doc """
  The fix text the install script prints when `python3` is missing: without it the script can't
  read the board's preflight answer, so it bakes this one in.
  """
  @spec python3_fix() :: String.t()
  def python3_fix, do: Enum.find(@preflight_checks, &(&1.id == "python3")).fix

  # ---------------------------------------------------------------- install handshake

  @doc """
  The install script's preflight, authenticated by `key` (board preloaded). `params` carries the
  `slug` the script was served for, `machine`, `repo_dir`, `remote`, `branch`, the local `checks`
  (every `preflight_checks/0` id, each `%{"id", "ok", "detail"}`) and `clis` (cli => path | nil).

  Answers the board's name, the onboarding LLM, every check with its fix text (the local ones, then
  `cli` and `key`), and the first failure's `headline` / `fix` / `fix_command`. On a board with a
  checklist it ticks step 3 (the key's first authed call) — or confirms a step 3 `key_saved/1`
  finished, rewriting its evidence and merging `data["machine"]` — and marks step 4 `:waiting` or
  `:failed`; a step already past is left alone. Refuses a key from another board (`:wrong_board`), a board
  still on step 1–2 (`:step_2_pending`) and a malformed request (`:invalid`), writing nothing.
  """
  @spec preflight(ApiKey.t(), map()) :: {:ok, map()} | {:error, :wrong_board | :step_2_pending | :invalid}
  def preflight(%ApiKey{board: %Board{} = board} = key, params) when is_map(params) do
    target = target_for_key(key)

    with {:ok, req} <- parse_preflight(params),
         :ok <- same_board(board, req.slug),
         {:ok, current_id} <- preflight_step(target) do
      llm = install_llm(board.id)
      checks = local_checks(req.checks) ++ [cli_check(llm, req.clis), key_check(key)]
      failed = Enum.find(checks, &(not &1["ok"]))
      failure = failure(failed, llm)

      record_preflight(target, current_id, %{key: key, machine: req.machine, checks: checks, failed: failed}, failure)

      {:ok,
       Map.merge(
         %{
           ok: is_nil(failed),
           board: board.name,
           llm: Map.take(llm, [:harness, :label, :cli, :skill_dir, :skill_path, :pointer_file]),
           relay_files: Scaffold.items(llm.skill_dir),
           checks: checks
         },
         failure
       )}
    end
  end

  def preflight(%ApiKey{}, _params), do: {:error, :invalid}

  @doc """
  The install script's success report, authenticated by `key` (board preloaded): `params` carries
  `slug`, `machine`, `repo_dir`, `branch` and the `files` it wrote. Finishes step 4 when it is the
  current step (activating step 5); otherwise writes nothing. `{:ok, %{ok: true}}`, or
  `{:error, :wrong_board | :invalid}`.
  """
  @spec installed(ApiKey.t(), map()) :: {:ok, map()} | {:error, :wrong_board | :invalid}
  def installed(%ApiKey{board: %Board{} = board} = key, params) when is_map(params) do
    target = target_for_key(key)

    with {:ok, req} <- parse_installed(params),
         :ok <- same_board(board, req.slug) do
      with %{id: @install_step} <- current(target) do
        advance(target, @install_step, :done, %{
          evidence: "downloaded #{hhmm(now())} · #{req.repo_dir} · #{req.branch}",
          data: %{"files" => req.files}
        })
      end

      {:ok, %{ok: true}}
    end
  end

  def installed(%ApiKey{}, _params), do: {:error, :invalid}

  defp parse_preflight(%{"slug" => slug, "checks" => checks} = params) when is_binary(slug) and is_list(checks) do
    with {:ok, strings} <- strings(params, [:machine, :repo_dir, :remote, :branch]),
         {:ok, checks} <- parse_checks(checks),
         {:ok, clis} <- parse_clis(Map.get(params, "clis", %{})) do
      {:ok, Map.merge(strings, %{slug: slug, checks: checks, clis: clis})}
    end
  end

  defp parse_preflight(_params), do: {:error, :invalid}

  defp parse_installed(%{"slug" => slug, "files" => files} = params) when is_binary(slug) and is_list(files) do
    with true <- Enum.all?(files, &is_binary/1),
         {:ok, strings} <- strings(params, [:machine, :repo_dir, :branch]) do
      {:ok, Map.merge(strings, %{slug: slug, files: files})}
    else
      _ -> {:error, :invalid}
    end
  end

  defp parse_installed(_params), do: {:error, :invalid}

  # Optional string fields: absent or null reads as "".
  defp strings(params, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.get(params, Atom.to_string(key)) do
        nil -> {:cont, {:ok, Map.put(acc, key, "")}}
        value when is_binary(value) -> {:cont, {:ok, Map.put(acc, key, value)}}
        _ -> {:halt, {:error, :invalid}}
      end
    end)
  end

  # Every local check id exactly once, each with a boolean `ok`.
  defp parse_checks(checks) do
    parsed = Enum.map(checks, &parse_check/1)

    if nil not in parsed and Enum.sort(Enum.map(parsed, &elem(&1, 0))) == Enum.sort(@preflight_ids),
      do: {:ok, Map.new(parsed)},
      else: {:error, :invalid}
  end

  defp parse_check(%{"id" => id, "ok" => ok} = check) when id in @preflight_ids and is_boolean(ok) do
    case Map.get(check, "detail") do
      detail when is_binary(detail) -> {id, %{ok: ok, detail: detail}}
      nil -> {id, %{ok: ok, detail: ""}}
      _ -> nil
    end
  end

  defp parse_check(_check), do: nil

  defp parse_clis(clis) when is_map(clis) do
    if Enum.all?(clis, fn {cli, value} -> is_binary(cli) and (is_binary(value) or is_nil(value)) end),
      do: {:ok, clis},
      else: {:error, :invalid}
  end

  defp parse_clis(_clis), do: {:error, :invalid}

  defp same_board(%Board{slug: slug}, slug), do: :ok
  defp same_board(_board, _slug), do: {:error, :wrong_board}

  # The step a preflight reports into: nil when the target has no checklist (or it is finished). A
  # machine's steps 1 and 2 are skipped, so a machine key is never `:step_2_pending`.
  defp preflight_step(target) do
    case current(target) do
      nil -> {:ok, nil}
      %{id: id} -> with(:ok <- past_llm_step(id), do: {:ok, id})
    end
  end

  defp past_llm_step(current_id) when current_id in [@created_step, @llm_step], do: {:error, :step_2_pending}
  defp past_llm_step(_current_id), do: :ok

  # The checklist's onboarding LLM; a board with no checklist uses its default agent's. A disabled
  # LLM can't be installed, so it falls back to the default harness's.
  defp install_llm(board_id) do
    case checklist_llm(board_id, read_rows({board_id, nil})) do
      %{enabled?: true} = llm -> llm
      _disabled -> onboarding_llm(Agents.default_harness_key())
    end
  end

  # String keys throughout: the checks are stored in the step's jsonb `data` as they are returned.
  defp local_checks(given) do
    for %{id: id, label: label, fix: fix} <- @preflight_checks do
      %{ok: ok, detail: detail} = given[id]
      %{"id" => id, "label" => label, "ok" => ok, "detail" => detail, "fix" => if(not ok, do: fix)}
    end
  end

  defp cli_check(llm, clis) do
    found = clis[llm.cli]
    ok = is_binary(found) and String.trim(found) != ""

    %{
      "id" => "cli",
      "label" => "#{llm.cli} on PATH",
      "ok" => ok,
      "detail" => if(ok, do: found, else: "#{llm.cli} not found"),
      "fix" => if(not ok, do: cli_fix())
    }
  end

  defp cli_fix, do: "Install it, open a new terminal, and #{@nothing_written}"

  defp key_check(%ApiKey{last_four: four}) do
    %{
      "id" => "key",
      "label" => "RELAY_API_KEY",
      "ok" => true,
      "detail" => "accepted by the board (…#{four})",
      "fix" => nil
    }
  end

  defp failure(nil, _llm), do: %{headline: nil, fix: nil, fix_command: nil}

  defp failure(%{"id" => "cli"}, llm),
    do: %{headline: "Preflight stopped: #{llm.label} isn't on your PATH", fix: cli_fix(), fix_command: llm.install}

  defp failure(%{"id" => id}, _llm) do
    check = Enum.find(@preflight_checks, &(&1.id == id))
    Map.take(check, [:headline, :fix, :fix_command])
  end

  # Step 3 ticks on the key's first authed call; then step 4 records the result. A step already
  # past is left alone, and `advance/4` writes nothing for a repeat that changes nothing.
  defp record_preflight(target, @key_step, result, failure) do
    _ =
      advance(target, @key_step, :done, %{
        evidence: key_evidence(target, result),
        data: %{"machine" => result.machine}
      })

    record_install(target, result, failure)
  end

  # On step 4, a step 3 the user saved (`key_saved/1`) but no install has confirmed is confirmed
  # first — under the board lock, in step 4's transaction, so a remint can't reopen it in between.
  # Step 3 stays done (`completed_at` untouched); step 4's advance broadcasts the change.
  defp record_preflight(target, @install_step, result, failure) do
    Repo.transact(fn ->
      with {:ok, rows} <- lock(scope(target)) do
        confirm_saved_key!(rows, target, result)
        record_install(target, result, failure)
      end
    end)
  end

  defp record_preflight(_target, _step_id, _result, _failure), do: :ok

  defp key_evidence(target, result),
    do:
      Enum.join(
        minted_for(target) ++ ["first authed call #{hhmm(now())}", "key …#{result.key.last_four}", result.machine],
        " · "
      )

  defp confirm_saved_key!(rows, target, result) do
    if rows_key_unconfirmed?(rows) do
      row = rows[@key_step]

      row
      |> Ecto.Changeset.change(evidence: key_evidence(target, result), data: Map.put(row.data, "machine", result.machine))
      |> Repo.update!()
    end
  end

  defp record_install(target, %{failed: nil} = result, _failure) do
    advance(target, @install_step, :waiting, %{
      evidence: "preflight passed #{hhmm(now())} · #{result.machine}",
      data: %{"checks" => result.checks}
    })
  end

  defp record_install(target, %{failed: failed} = result, failure) do
    detail = if String.trim(failed["detail"]) == "", do: failed["label"], else: failed["detail"]

    advance(target, @install_step, :failed, %{
      error: failure.headline,
      evidence: "preflight failed #{hhmm(now())} · #{detail} · #{result.machine}",
      data: %{
        "checks" => result.checks,
        "headline" => failure.headline,
        "fix" => failure.fix,
        "fix_command" => failure.fix_command
      }
    })
  end

  # A machine's step-3 evidence names whose key it is: the board's own key is the board's.
  defp minted_for(%SetupMachine{} = machine) do
    case Repo.preload(machine, :user).user do
      nil -> []
      user -> ["minted for #{display_name(user)}"]
    end
  end

  defp minted_for(_board), do: []

  # ---------------------------------------------------------------- checklist

  @doc """
  Starts the board's checklist: one row per catalog id. Step 1 is done (its evidence is the
  `:evidence` given verbatim — a copied board passes `"copied from <name>"`, RE447 — else it counts
  the board's top-level stages and flows; its data carries the template's name and warning), step 2
  is active, the rest are pending. Runs inside `create_board`'s transaction, so it raises on
  failure. Broadcasts `{:setup_changed, board_id}` once.
  """
  @spec start(Board.t(), %{
          required(:name) => String.t(),
          optional(:warning) => String.t() | nil,
          optional(:evidence) => String.t(),
          optional(atom()) => any()
        }) ::
          :ok
  def start(%Board{id: board_id}, template) do
    now = now()

    created = %{
      status: :done,
      reached_at: now,
      completed_at: now,
      evidence: Map.get_lazy(template, :evidence, fn -> created_evidence(board_id, now) end),
      data: %{"template" => template.name, "template_warning" => Map.get(template, :warning)}
    }

    for %{id: id} <- @steps do
      fields =
        case id do
          @created_step -> created
          @llm_step -> %{status: :active, reached_at: now}
          _ -> %{status: :pending}
        end

      Repo.insert!(struct(BoardSetupStep, Map.merge(fields, %{board_id: board_id, step: id})))
    end

    Events.broadcast(board_id, {:setup_changed, board_id})
  end

  # Step 1's default evidence: the board's top-level stages and flows, and when it was made.
  defp created_evidence(board_id, now) do
    stages = Repo.aggregate(from(s in Stage, where: s.board_id == ^board_id and is_nil(s.parent_id)), :count)
    flows = Repo.aggregate(from(f in Flow, where: f.board_id == ^board_id), :count)
    "#{stages} stages · #{flows} flows · #{hhmm(now)}"
  end

  @doc """
  The checklist of a board — or of one connected machine (RE446) — every placeholder resolved: its
  template, the onboarding LLM, where it stands (`current_id`, `position`, `done_count`,
  `finished?`) and the 7 top-level entries (step 5's sub-steps in its `children`). A machine's
  checklist is a connect (`connect?: true`, see `connect_machine/2`). nil when there is none.
  """
  @spec checklist(Board.t() | SetupMachine.t() | integer()) :: checklist() | nil
  def checklist(target), do: target |> scope() |> scoped_checklist()

  defp scoped_checklist(scope) do
    case read_rows(scope) do
      rows when map_size(rows) == 0 -> nil
      rows -> build(scope, rows)
    end
  end

  @doc "A connected machine's checklist (`checklist/1`), by machine or id; nil when it is gone."
  @spec machine_checklist(SetupMachine.t() | integer()) :: checklist() | nil
  def machine_checklist(%SetupMachine{} = machine), do: checklist(machine)

  def machine_checklist(machine_id) when is_integer(machine_id) do
    with %SetupMachine{} = machine <- Repo.get(SetupMachine, machine_id), do: checklist(machine)
  end

  @doc """
  The connect-a-machine checklist `user` sees on `board`: their most recent unfinished machine's,
  else an unsaved preview (`machine_id: nil`, the `connect_skips/0` skipped, step 3 active, the
  rest pending) that inserts nothing. nil when the board has no checklist.
  """
  @spec connect_checklist(Board.t(), User.t()) :: checklist() | nil
  def connect_checklist(%Board{id: board_id}, %User{id: user_id}) do
    board_rows = read_rows({board_id, nil})

    if map_size(board_rows) > 0,
      do:
        latest_unfinished(board_id, user_id) ||
          preview_checklist(connect_rows(nil), connect_context(board_id, board_rows))
  end

  defp latest_unfinished(board_id, user_id) do
    from(m in SetupMachine,
      where: m.board_id == ^board_id and m.user_id == ^user_id,
      order_by: [desc: m.inserted_at, desc: m.id]
    )
    |> Repo.all()
    |> Enum.map(&checklist/1)
    |> Enum.find(&(&1 && not &1.finished?))
  end

  @doc """
  Connects `user`'s machine to `board` (RE446): mints a board key `"Setup · <name>"` in their name
  and inserts a `Schemas.SetupMachine` with its own checklist rows — every `connect_skips/0` step
  `:skipped` (step 1 `"already set up"`, step 2 `"board-wide · already chosen"`), step 3 `:active`
  with the key's id, the rest `:pending`. The board's own rows are untouched. Refused while the
  board is still on step 1 or 2. Broadcasts `{:setup_changed, board_id}` once. Returns the raw
  token — its only copy.
  """
  @spec connect_machine(Board.t(), User.t()) ::
          {:ok, %{machine: SetupMachine.t(), checklist: checklist(), token: String.t()}}
          | {:error, :no_checklist | :step_2_pending}
  def connect_machine(%Board{} = board, %User{} = user) do
    Repo.transact(fn ->
      with {:ok, board_rows} <- lock({board.id, nil}),
           :ok <- past_llm_step(current_id(board_rows)) do
        machine = insert_machine!(board, user)
        token = mint_key!(scope(machine), board, user)
        :ok = Events.broadcast(board.id, {:setup_changed, board.id})
        machine = Repo.get!(SetupMachine, machine.id)
        {:ok, %{machine: machine, checklist: checklist(machine), token: token}}
      end
    end)
  end

  defp insert_machine!(board, user) do
    machine = Repo.insert!(%SetupMachine{board_id: board.id, user_id: user.id})

    for {id, fields} <- connect_rows(now()) do
      Repo.insert!(struct(BoardSetupStep, Map.merge(fields, %{board_id: board.id, machine_id: machine.id, step: id})))
    end

    machine
  end

  @doc """
  Where a board key reports its setup: the connected machine it was minted for, else its board
  (`key.board`, preloaded here when it isn't). The install handshake, `GET /api/setup`,
  `POST /api/setup/steps/:step` and the heartbeat all route through it.
  """
  @spec target_for_key(ApiKey.t()) :: Board.t() | SetupMachine.t()
  def target_for_key(%ApiKey{} = key), do: machine_for_key(key) || Repo.preload(key, :board).board

  defp machine_for_key(%ApiKey{id: key_id}),
    do: Repo.one(from(m in SetupMachine, where: m.api_key_id == ^key_id, order_by: m.id, limit: 1))

  @doc """
  Every setup on `board`, for Board settings → Setup: the board's own first (only once its step 3
  has a key), then each connected machine, oldest first. A row carries `id` (`:board` or the
  machine's id), `machine` (step 6's host; else the board's step-3 preflight machine, or the
  machine row's `host`), `person` (whose key it is), `key_last_four` (nil once revoked),
  `harnesses` (the installed ones its step-6 runner reports, `[]` before a runner),
  `finished?` and `progress` (`"7/7"` / `"6/6"` once finished, else `"<current id> <short>"`).
  """
  @spec machines(Board.t()) :: [
          %{
            id: :board | integer(),
            machine: String.t() | nil,
            person: String.t() | nil,
            key_last_four: String.t() | nil,
            harnesses: [%{cli: String.t(), signed_in: boolean() | nil}],
            finished?: boolean(),
            progress: String.t()
          }
        ]
  def machines(%Board{id: board_id}) do
    board_rows = read_rows({board_id, nil})
    runners = Map.new(Repo.all(from(r in Runner, where: r.board_id == ^board_id)), &{&1.name, &1})

    machines =
      Repo.all(
        from(m in SetupMachine,
          where: m.board_id == ^board_id,
          order_by: [asc: m.inserted_at, asc: m.id],
          preload: [:user, :api_key]
        )
      )

    board_row(board_id, board_rows, runners) ++ Enum.map(machines, &machine_row(&1, runners))
  end

  defp board_row(board_id, %{@key_step => %{data: %{"key_id" => key_id} = key_data}} = rows, runners)
       when not is_nil(key_id) do
    key = Repo.one(from(k in ApiKey, where: k.id == ^key_id, preload: :created_by))
    checklist = build({board_id, nil}, rows)
    runner_data = rows[@runner_step].data

    [
      %{
        id: :board,
        machine: runner_data["host"] || key_data["machine"],
        person: key && display_name(key.created_by),
        key_last_four: key && key.last_four,
        harnesses: runner_harnesses(runners, runner_data["runner"]),
        finished?: checklist.finished?,
        progress: progress(checklist)
      }
    ]
  end

  defp board_row(_board_id, _rows, _runners), do: []

  defp machine_row(machine, runners) do
    checklist = checklist(machine)
    runner_data = Enum.find(checklist.steps, &(&1.id == @runner_step)).data

    %{
      id: machine.id,
      machine: runner_data["host"] || machine.host,
      person: display_name(machine.user),
      key_last_four: machine.api_key && machine.api_key.last_four,
      harnesses: runner_harnesses(runners, runner_data["runner"]),
      finished?: checklist.finished?,
      progress: progress(checklist)
    }
  end

  defp runner_harnesses(runners, name) do
    case runners[name] do
      %Runner{harnesses: harnesses} ->
        for %{"key" => key, "installed" => true} = harness <- harnesses || [],
            do: %{cli: harness_cli(key), signed_in: harness["signed_in"]}

      nil ->
        []
    end
  end

  defp progress(%{finished?: true, total: total}), do: "#{total}/#{total}"

  defp progress(%{current_id: current_id, steps: steps}),
    do: "#{current_id} #{Enum.find(steps, &(&1.id == current_id)).short}"

  @doc """
  The onboarding answers for Board settings → Setup: 5.3's `data["answers"]` in
  `interview_questions/0` order, the answered (non-blank) ones only. `[]` when there are none or
  the board has no checklist.
  """
  @spec project_answers(Board.t()) :: [%{id: String.t(), label: String.t(), answer: String.t()}]
  def project_answers(%Board{} = board) do
    answers =
      case Repo.one(from(s in rows_query(scope(board)), where: s.step == ^@interview_step, select: s.data)) do
        %{"answers" => %{} = answers} -> answers
        _none -> %{}
      end

    for %{id: id, label: label} <- @interview_questions,
        answer = answers[id],
        is_binary(answer) and String.trim(answer) != "",
        do: %{id: id, label: label, answer: answer}
  end

  @doc """
  The one step a report may move: the current sub-step when the current top-level step has
  children, else the current top-level step; nil when the checklist is finished.
  """
  @spec reportable_id(checklist()) :: String.t() | nil
  def reportable_id(%{current_sub_id: sub_id, current_id: current_id}), do: sub_id || current_id

  @doc "The step the checklist is on: the first top-level entry not finished, or nil."
  @spec current(Board.t() | SetupMachine.t() | integer()) :: entry() | nil
  def current(target) do
    case checklist(target) do
      nil -> nil
      %{steps: steps} -> Enum.find(steps, &(not finished_status?(&1.status)))
    end
  end

  @doc """
  One progress row per board with a checklist, for the superadmin `/admin/onboarding` page
  (RE448), newest board first (`inserted_at`, then id, descending). Unscoped on purpose: the gate
  is the `/admin` route. two queries (steps joined to their board and its owner; every board's first flow stage), each checklist
  built by `preview_checklist/2`.

  A row carries the board's `board_id`, `name`, `slug`, `owner_email` and `inserted_at`; step 1's
  `template`; the `llm` label step 2 picked (nil before); the `current` entry (`id`, `title`,
  `status`, `actor` — step 5's first current sub-step while on step 5, step 7 once finished);
  `on_step` (seconds since the current top-level step was reached, nil once finished) and `total`
  (seconds from step 1's completion to step 7's, or to `now`); `last` — the latest failed step's
  error or else evidence, walking the catalog backwards; `stuck?` (`on_step > stuck_after/0`);
  `state` (one of `admin_states/0`) and the full `checklist`.
  """
  @spec list_for_admin(DateTime.t()) :: [admin_row()]
  def list_for_admin(now \\ now()) do
    from(s in BoardSetupStep,
      join: b in assoc(s, :board),
      left_join: o in assoc(b, :owner),
      where: is_nil(s.machine_id),
      order_by: [desc: b.inserted_at, desc: b.id],
      select: {s, %{board_id: b.id, name: b.name, slug: b.slug, inserted_at: b.inserted_at, owner_email: o.email}}
    )
    |> Repo.all()
    |> Enum.chunk_by(fn {_step, board} -> board.board_id end)
    |> admin_rows(now)
  end

  @doc """
  Moves the reportable step (`reportable_id/1`) to `status` (`:waiting | :done | :failed |
  :skipped`). `attrs` may carry `evidence`, `error` (kept only for `:failed`) and `data` (merged
  into the row's data at the top level only), with atom or string keys. `:done` / `:skipped`
  complete the step and activate the next one — the next sub-step, or, after the last, the
  parent finishes and the next top-level step activates. A
  repeat that would change nothing returns `{:ok, checklist}` without writing or broadcasting —
  on the reportable step, or the repeat of the transition that just finished the step before it;
  an older finished step is `{:error, :not_current}`. Any change broadcasts
  `{:setup_changed, board_id}` once. Serialized on the board row.
  """
  @spec advance(Board.t() | SetupMachine.t() | integer(), String.t(), atom(), map()) ::
          {:ok, checklist()} | {:error, :not_current | :no_checklist | :invalid_status}
  def advance(target, step_id, status, attrs) when is_binary(step_id) and is_map(attrs) do
    if status in @advance_statuses,
      do: Repo.transact(fn -> locked_advance(scope(target), step_id, status, attrs) end),
      else: {:error, :invalid_status}
  end

  @doc """
  Step 2: makes `harness_key`'s LLM the board's default agent (the default already on that harness
  stays; else the board's first agent on it; else a new one on the harness's first model), finishes
  step 2 and mints the step-3 board key in `user`'s name. Returns the raw token — its only copy.
  """
  @spec choose_llm(Board.t(), User.t(), String.t()) ::
          {:ok, %{checklist: checklist(), token: String.t()}} | {:error, :not_current | :unknown_llm | :disabled_llm}
  def choose_llm(%Board{} = board, %User{} = user, harness_key) do
    Repo.transact(fn ->
      with {:ok, rows} <- lock_current({board.id, nil}, @llm_step),
           {:ok, llm} <- enabled_llm(harness_key) do
        :ok = make_default!(board, llm)

        :ok =
          apply_advance(rows, @llm_step, :done, %{
            evidence: "chosen #{hhmm(now())} · change in Settings",
            data: %{"llm" => llm.harness}
          })

        # step 2's advance above already queued the one broadcast for this change
        token = mint_key!({board.id, nil}, board, user)
        {:ok, %{checklist: checklist(board.id), token: token}}
      end
    end)
  end

  @doc """
  Step 3, on the user's say-so ("I've saved it — next", RE455): finishes the board's or a connected
  machine's step 3 as saved but not yet confirmed (`data["saved"]`), which activates step 4. The
  install script's first authed call confirms it later (`preflight/2`). `{:error, :not_current}`
  unless step 3 is the reportable step.
  """
  @spec key_saved(Board.t() | SetupMachine.t()) :: {:ok, checklist()} | {:error, :not_current | :no_checklist}
  def key_saved(target) when is_struct(target, Board) or is_struct(target, SetupMachine) do
    advance(target, @key_step, :done, %{
      evidence: "saved #{hhmm(now())} · confirmed when the install script calls in",
      data: %{"saved" => true}
    })
  end

  @doc """
  True while step 3 is saved (`key_saved/1`) but the install script hasn't called in with the key
  yet, and step 4 is still current — when "Lost it? Mint a new key" (`remint_key/2`) applies.
  """
  @spec key_unconfirmed?(checklist()) :: boolean()
  def key_unconfirmed?(%{current_id: current_id, steps: steps}) do
    %{status: status, data: data} = Enum.find(steps, &(&1.id == @key_step))
    key_unconfirmed?(current_id, status, data)
  end

  # The ONE reading of step 3's `"saved"` / `"machine"` data keys, for a checklist and locked rows.
  defp key_unconfirmed?(@install_step, :done, %{"saved" => true} = data), do: is_nil(data["machine"])
  defp key_unconfirmed?(_current_id, _status, _data), do: false

  defp rows_key_unconfirmed?(rows), do: key_unconfirmed?(current_id(rows), rows[@key_step].status, rows[@key_step].data)

  @doc """
  Step 3: mints a fresh board key in `user`'s name and points step 3 at it — the board's, or a
  connected machine's (which also moves `machine.api_key_id`). The previous setup key is revoked
  when it was never used; a key a runner already used stays. Returns the raw token once.

  Allowed while step 3 is current, or while it is saved but unconfirmed (`key_unconfirmed?/1`):
  then step 3 reopens (active, its `"saved"` mark dropped) and step 4 goes back to pending.
  """
  @spec remint_key(Board.t() | SetupMachine.t(), User.t()) ::
          {:ok, %{checklist: checklist(), token: String.t()}} | {:error, :not_current}
  def remint_key(target, %User{} = user) when is_struct(target, Board) or is_struct(target, SetupMachine) do
    {board_id, _machine_id} = scope = scope(target)

    Repo.transact(fn ->
      with {:ok, rows} <- lock_rekeyable(scope) do
        reopen_saved_key!(rows)
        :ok = revoke_unused_key(board_id, rows[@key_step])
        token = mint_key!(scope, target_board(target), user)
        :ok = Events.broadcast(board_id, {:setup_changed, board_id})
        {:ok, %{checklist: scoped_checklist(scope), token: token}}
      end
    end)
  end

  # Step 3 can be re-keyed while it is current, or while it is saved but unconfirmed.
  defp lock_rekeyable(scope) do
    with {:ok, rows} <- lock(scope),
         true <- current_id(rows) == @key_step or rows_key_unconfirmed?(rows) do
      {:ok, rows}
    else
      _ -> {:error, :not_current}
    end
  end

  # Only steps 3 and 4 move: step 4 can't have advanced without a preflight, which confirms step 3.
  defp reopen_saved_key!(rows) do
    if current_id(rows) != @key_step, do: reopen_key_step!(rows)
  end

  defp reopen_key_step!(rows) do
    key = rows[@key_step]

    key
    |> Ecto.Changeset.change(status: :active, evidence: nil, completed_at: nil, data: Map.delete(key.data, "saved"))
    |> Repo.update!()

    rows[@install_step] |> Ecto.Changeset.change(status: :pending, reached_at: nil, evidence: nil) |> Repo.update!()
  end

  defp target_board(%Board{} = board), do: board
  defp target_board(%SetupMachine{board_id: board_id}), do: Repo.get!(Board, board_id)

  # ---------------------------------------------------------------- board-observed sub-steps

  @doc """
  Called by `Relay.Flows` after a flow push (`upsert_from_document/3`) committed. While 5.5 is
  the current sub-step it records `flow_key` in 5.5's `data["pushed"]`; once every board flow has
  been pushed and is enabled 5.5 finishes (`"N flows enabled"`), else it waits
  (`"P of N flows pushed"`). Otherwise a no-op. Always `:ok`: a push never fails on setup state.
  """
  @spec observe_flow_push(integer(), String.t()) :: :ok
  def observe_flow_push(board_id, flow_key) when is_integer(board_id) and is_binary(flow_key),
    do: observe({board_id, nil}, @push_step, &push_change(board_id, &1, flow_key))

  @doc """
  Called by `Relay.Cards` after a card create committed. While 5.8 is the current sub-step, a
  card in the first flow stage (or one of its substages) finishes 5.8 (`"first card in <stage>"`)
  — and with it step 5. Otherwise a no-op. Always `:ok`.
  """
  @spec observe_card_created(Card.t()) :: :ok
  def observe_card_created(%Card{board_id: board_id, stage_id: stage_id}),
    do: observe({board_id, nil}, @first_card_step, fn _row -> first_card_change(board_id, stage_id) end)

  @doc """
  Called by `RelayWeb.Api.NodeJobController` on every runner heartbeat, with the post-upsert
  `runner`. While step 6 is the reportable step of the key's setup (`target_for_key/1`: its
  connected machine's, else its board's) it finishes step 6 (`"heartbeat HH:MM · <machine>"`, then
  `" · <cli> logged_in|logged_out|installed, …"` for each installed harness) and activates the
  next step; a machine's tick also records `host` / `runner_name` on its `setup_machines` row.
  `<machine>` is the runner's host, else its name. A machine key never touches the board's rows,
  nor a board key a machine's. Otherwise a no-op. Always `:ok`: the heartbeat is the runner's
  liveness path.
  """
  @spec observe_heartbeat(ApiKey.t(), Runner.t()) :: :ok
  def observe_heartbeat(%ApiKey{board_id: board_id} = key, %Runner{} = runner) when is_integer(board_id) do
    target = target_for_key(key)
    observe(scope(target), @runner_step, fn _row -> heartbeat_change(target, runner) end)
  end

  def observe_heartbeat(_key, _runner), do: :ok

  @doc """
  Called by `Relay.Runs.claim_next_job/4` after a claim committed. While step 7 is the reportable
  step of the job's board setup it finishes step 7 (`"<REF> claimed HH:MM by <runner>"`) — and
  with it the checklist — storing the payoff facts in its `data`: `card_ref`, `card_id`,
  `runner`, `machine` and the `verb` for the card's stage category at claim time. Otherwise a
  no-op, including for a card that no longer exists. Always `:ok`: a claim never fails on setup.
  """
  @spec observe_claim(NodeJob.t(), Runner.t()) :: :ok
  def observe_claim(%NodeJob{card_id: card_id}, %Runner{} = runner) when is_integer(card_id) do
    case Repo.one(from(c in Card, where: c.id == ^card_id, select: c.board_id)) do
      nil -> :ok
      board_id -> observe({board_id, nil}, @claim_step, fn _row -> claim_change(card_id, runner) end)
    end
  end

  def observe_claim(_job, _runner), do: :ok

  @doc """
  Closes a finished setup: stamps step 7's `data["callout_dismissed_at"]` (kept if already set)
  and `data["closed_at"]`, so the checklist reads `closed?: true, callout: nil`. A repeat writes
  nothing. Broadcasts `{:setup_changed, board_id}` on a change. Serialized on the board row.
  """
  @spec close(Board.t() | integer()) :: {:ok, checklist()} | {:error, :no_checklist | :not_finished}
  def close(board) do
    board_id = board_id(board)

    Repo.transact(fn ->
      with {:ok, rows} <- lock({board_id, nil}),
           :ok <- finished(rows) do
        stamp = DateTime.to_iso8601(now())
        row = rows[@claim_step]

        :ok =
          write_payoff!(row, row.data |> Map.put_new("callout_dismissed_at", stamp) |> Map.put_new("closed_at", stamp))

        {:ok, checklist(board_id)}
      end
    end)
  end

  @doc """
  Reopens a closed setup: clears step 7's `data["closed_at"]` only, so the callout stays
  dismissed. Broadcasts `{:setup_changed, board_id}` on a change. Serialized on the board row.
  """
  @spec reopen(Board.t() | integer()) :: {:ok, checklist()} | {:error, :no_checklist}
  def reopen(board) do
    board_id = board_id(board)

    Repo.transact(fn ->
      with {:ok, rows} <- lock({board_id, nil}) do
        row = rows[@claim_step]
        :ok = write_payoff!(row, Map.delete(row.data, "closed_at"))
        {:ok, checklist(board_id)}
      end
    end)
  end

  defp finished(rows), do: if(current_id(rows), do: {:error, :not_finished}, else: :ok)

  defp write_payoff!(%{data: data}, data), do: :ok

  defp write_payoff!(row, data) do
    row |> Ecto.Changeset.change(data: data) |> Repo.update!()
    Events.broadcast(row.board_id, {:setup_changed, row.board_id})
  end

  # A cheap unlocked check first (most writes happen on boards not sitting on this sub-step),
  # then the locked re-check and the advance. `change` answers `{status, attrs}` or nil.
  defp observe(scope, step_id, change) do
    if observable?(scope, step_id) do
      {:ok, _} = Repo.transact(fn -> {:ok, locked_observe(scope, step_id, change)} end)
    end

    :ok
  end

  defp observable?(scope, step_id) do
    Repo.exists?(
      from(s in rows_query(scope),
        where: s.step == ^step_id and s.status not in ^BoardSetupStep.finished_statuses()
      )
    )
  end

  defp locked_observe(scope, step_id, change) do
    with {:ok, rows} <- lock(scope),
         ^step_id <- rows_reportable_id(rows),
         {status, attrs} <- change.(rows[step_id]) do
      apply_advance(rows, step_id, status, attrs)
    end
  end

  defp push_change(board_id, row, flow_key) do
    flows = Repo.all(from(f in Flow, where: f.board_id == ^board_id, select: {f.key, f.enabled}))
    pushed = Enum.uniq(Map.get(row.data, "pushed", []) ++ [flow_key])
    total = length(flows)
    pushed_count = Enum.count(flows, fn {key, _enabled} -> key in pushed end)
    data = %{"pushed" => pushed}

    if pushed_count == total and Enum.all?(flows, fn {_key, enabled} -> enabled end),
      do: {:done, %{evidence: "#{total} flows enabled", data: data}},
      else: {:waiting, %{evidence: "#{pushed_count} of #{total} flows pushed", data: data}}
  end

  defp first_card_change(board_id, stage_id) do
    with {first_id, name} <- board_id |> first_flow_stage_query() |> select([_f, s], {s.id, s.name}) |> Repo.one(),
         true <- stage_id == first_id or Repo.get(Stage, stage_id).parent_id == first_id do
      {:done, %{evidence: "first card in #{name}"}}
    else
      _ -> nil
    end
  end

  # A machine's step-6 tick also names the machine; this runs inside the locked advance, only once
  # step 6 is the machine's reportable step.
  defp heartbeat_change(%SetupMachine{id: id}, runner) do
    {1, _} =
      Repo.update_all(from(m in SetupMachine, where: m.id == ^id),
        set: [host: machine(runner), runner_name: runner.name, updated_at: now()]
      )

    heartbeat_change(runner)
  end

  defp heartbeat_change(%Board{}, runner), do: heartbeat_change(runner)

  defp heartbeat_change(runner) do
    machine = machine(runner)

    harnesses =
      for %{"key" => key, "installed" => true} = harness <- runner.harnesses || [] do
        %{"cli" => harness_cli(key), "signed_in" => harness["signed_in"]}
      end

    parts = for %{"cli" => cli, "signed_in" => signed_in} <- harnesses, do: "#{cli} #{sign_in(signed_in)}"
    tail = if parts == [], do: [], else: [Enum.join(parts, ", ")]

    {:done,
     %{
       evidence: Enum.join(["heartbeat #{hhmm(now())}", machine | tail], " · "),
       data: %{"host" => machine, "runner" => runner.name, "harnesses" => harnesses}
     }}
  end

  defp harness_cli(key) do
    case onboarding_llm(key) do
      %{cli: cli} -> cli
      nil -> key
    end
  end

  defp sign_in(true), do: "logged_in"
  defp sign_in(false), do: "logged_out"
  defp sign_in(_unknown), do: "installed"

  defp machine(%Runner{host: host, name: name}) do
    if is_binary(host) and String.trim(host) != "", do: host, else: name
  end

  # The card's ref and stage category at claim time; nil (a no-op) when the card is gone.
  defp claim_change(card_id, runner) do
    query =
      from(c in Card,
        join: b in assoc(c, :board),
        join: s in assoc(c, :stage),
        where: c.id == ^card_id,
        select: {b.key, c.ref_number, s.category}
      )

    with {key, ref_number, category} <- Repo.one(query) do
      ref = Card.format_ref(key, ref_number)

      {:done,
       %{
         evidence: "#{ref} claimed #{hhmm(now())} by #{runner.name}",
         data: %{
           "card_ref" => ref,
           "card_id" => card_id,
           "runner" => runner.name,
           "machine" => machine(runner),
           "verb" => Map.get(@claim_verbs, category, @claim_verb_default)
         }
       }}
    end
  end

  # ---------------------------------------------------------------- internals

  # A checklist's rows are a scope: `{board_id, nil}` for the board's own (`machine_id` nil), or
  # `{board_id, machine_id}` for one connected machine's. Every row read goes through `rows_query/1`.
  defp scope(%Board{id: id}), do: {id, nil}
  defp scope(%SetupMachine{board_id: board_id, id: id}), do: {board_id, id}
  defp scope(id) when is_integer(id), do: {id, nil}

  defp rows_query({board_id, nil}), do: from(s in BoardSetupStep, where: s.board_id == ^board_id and is_nil(s.machine_id))

  defp rows_query({_board_id, machine_id}), do: from(s in BoardSetupStep, where: s.machine_id == ^machine_id)

  defp read_rows(scope), do: scope |> rows_query() |> Repo.all() |> Map.new(&{&1.step, &1})

  # Like `Agents.ensure_seeded!/1`: lock the board row so two callers can't both advance. A machine's
  # checklist locks its board's row too.
  defp lock({board_id, _machine_id} = scope) do
    _ = Repo.one(from(b in Board, where: b.id == ^board_id, select: b.id, lock: "FOR UPDATE"))

    case read_rows(scope) do
      rows when map_size(rows) == 0 -> {:error, :no_checklist}
      rows -> {:ok, rows}
    end
  end

  defp lock_current(scope, step_id) do
    with {:ok, rows} <- lock(scope),
         ^step_id <- current_id(rows) do
      {:ok, rows}
    else
      _ -> {:error, :not_current}
    end
  end

  defp locked_advance(scope, step_id, status, attrs) do
    with {:ok, rows} <- lock(scope),
         :ok <- apply_advance(rows, step_id, status, attrs) do
      {:ok, scoped_checklist(scope)}
    end
  end

  defp apply_advance(rows, step_id, status, attrs) when is_map_key(rows, step_id) do
    row = rows[step_id]
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    change = %{
      status: status,
      evidence: Map.get(attrs, "evidence", row.evidence),
      error: if(status == :failed, do: attrs["error"]),
      data: Map.merge(row.data, attrs["data"] || %{})
    }

    reportable_id = rows_reportable_id(rows)

    cond do
      unchanged?(row, change) and step_id in [reportable_id, just_finished_id(reportable_id)] -> :ok
      reportable_id != step_id -> {:error, :not_current}
      true -> write_advance!(rows, row, change)
    end
  end

  defp apply_advance(_rows, _step_id, _status, _attrs), do: {:error, :not_current}

  defp unchanged?(row, change), do: Map.take(row, Map.keys(change)) == change

  defp write_advance!(rows, row, change) do
    now = now()
    finishing? = finished_status?(change.status)
    completed_at = if finishing?, do: now, else: row.completed_at

    row |> Ecto.Changeset.change(Map.put(change, :completed_at, completed_at)) |> Repo.update!()

    if finishing?, do: finish!(rows, row, now)
    Events.broadcast(row.board_id, {:setup_changed, row.board_id})
  end

  # A finished top-level step activates the next one. A finished child activates its next
  # unfinished sibling; after the last, the parent finishes and the next top-level step activates.
  defp finish!(rows, %{step: step_id}, now) do
    case Enum.find(@steps, &(&1.id == step_id)).parent do
      nil ->
        activate_next!(rows, step_id, now)

      parent_id ->
        siblings = @child_ids |> Map.fetch!(parent_id) |> Enum.drop_while(&(&1 != step_id)) |> tl()

        case Enum.find(siblings, &(not finished_status?(rows[&1].status))) do
          nil ->
            rows[parent_id]
            |> Ecto.Changeset.change(status: :done, completed_at: now, evidence: "onboarded #{hhmm(now)}")
            |> Repo.update!()

            activate_next!(rows, parent_id, now)

          next ->
            activate!(rows[next], now)
        end
    end
  end

  # Activating a step that has children activates its first child too.
  defp activate_next!(rows, step_id, now) do
    next =
      @top_ids
      |> Enum.drop_while(&(&1 != step_id))
      |> Enum.find(&(rows[&1].status == :pending))

    if next do
      activate!(rows[next], now)
      with [first | _] <- Map.get(@child_ids, next), do: activate!(rows[first], now)
    end
  end

  defp activate!(%{status: :pending} = row, now),
    do: row |> Ecto.Changeset.change(status: :active, reached_at: now) |> Repo.update!()

  defp activate!(_row, _now), do: :ok

  defp current_id(rows), do: Enum.find(@top_ids, &(not finished_status?(rows[&1].status)))

  # The first unfinished child of the current top-level step: derived from finished-ness, not
  # `:active`, so a board that reached step 5 before sub-steps activated still reports 5.1.
  # The step walked just before the reportable one (the last step when the checklist is finished):
  # re-reporting the transition that finished it is a harmless no-op, not a refusal.
  defp just_finished_id(nil), do: List.last(@walk_ids)
  defp just_finished_id(reportable_id), do: @walk_ids |> Enum.take_while(&(&1 != reportable_id)) |> List.last()

  defp rows_reportable_id(rows) do
    current_id = current_id(rows)
    current_sub_id(rows, current_id) || current_id
  end

  defp current_sub_id(rows, current_id) do
    Enum.find(Map.get(@child_ids, current_id, []), &(not finished_status?(rows[&1].status)))
  end

  defp enabled_llm(harness_key) do
    case onboarding_llm(harness_key) do
      nil -> {:error, :unknown_llm}
      %{enabled?: false} -> {:error, :disabled_llm}
      llm -> {:ok, llm}
    end
  end

  defp make_default!(board, %{harness: key} = llm) do
    case Agents.default_agent(board) do
      %{harness: %{key: ^key}} ->
        :ok

      _ ->
        agent = Enum.find(Agents.list_agents(board), &(&1.harness.key == key)) || create_agent!(board, llm)
        {:ok, _} = Agents.set_default_agent(board, agent)
        :ok
    end
  end

  # Mirrors `Boards.seed_template_agents!/2`: the agent takes the harness's FIRST listed model.
  defp create_agent!(board, %{harness: key, label: name}) do
    %{id: harness_id, models: [model | _]} = Enum.find(Agents.list_harnesses(board), &(&1.key == key))
    {:ok, agent} = Agents.create_agent(board, %{"name" => name, "harness_id" => harness_id, "model" => model})
    agent
  end

  # Writes the new key's id to the scope's step 3 — and, for a machine, to `machine.api_key_id`.
  defp mint_key!({_board_id, machine_id} = scope, board, user) do
    {:ok, %{api_key: api_key, token: token}} = ApiKeys.create_key(board, user, key_name(user))
    row = Repo.one!(from(s in rows_query(scope), where: s.step == ^@key_step))

    row
    |> Ecto.Changeset.change(data: Map.put(row.data, "key_id", api_key.id))
    |> Repo.update!()

    if machine_id do
      {1, _} =
        Repo.update_all(from(m in SetupMachine, where: m.id == ^machine_id),
          set: [api_key_id: api_key.id, updated_at: now()]
        )
    end

    token
  end

  defp key_name(user), do: String.slice("Setup · #{display_name(user)}", 0, ApiKey.name_max_length())

  defp display_name(nil), do: nil
  defp display_name(%User{} = user), do: user.name || user.email

  defp revoke_unused_key(board_id, row) do
    with id when not is_nil(id) <- row.data["key_id"],
         %ApiKey{last_used_at: nil} = key <- Repo.get_by(ApiKey, id: id, board_id: board_id) do
      {:ok, _} = ApiKeys.revoke(key)
    end

    :ok
  end

  defp build({board_id, nil}, rows), do: build(board_id, rows, checklist_llm(board_id, rows), first_flow_stage(board_id))

  defp build({board_id, machine_id}, rows),
    do: preview_checklist(rows, Map.put(connect_context(board_id, read_rows({board_id, nil})), :machine_id, machine_id))

  defp build(board_id, rows, llm, first_flow_stage),
    do: preview_checklist(rows, board_context(board_id, rows, llm, first_flow_stage))

  defp board_context(board_id, board_rows, llm, first_flow_stage) do
    created = board_rows[@created_step]

    %{
      board_id: board_id,
      template: created && created.data["template"],
      template_warning: created && created.data["template_warning"],
      llm: llm,
      first_flow_stage: first_flow_stage
    }
  end

  # A connect reads the board's template, LLM and name, and its step 7 for the board-wide evidence.
  defp connect_context(board_id, board_rows) do
    board_id
    |> board_context(board_rows, checklist_llm(board_id, board_rows), first_flow_stage(board_id))
    |> Map.merge(%{
      connect?: true,
      board_name: Repo.one!(from(b in Board, where: b.id == ^board_id, select: b.name)),
      board_claim: board_rows[@claim_step]
    })
  end

  # A connect's rows before anything ran (`connect_skips/0` skipped, step 3 active, the rest
  # pending), as `preview_row/1` fields; `reached_at` is nil for an unsaved preview.
  defp connect_rows(now) do
    Map.new(@steps, fn %{id: id} ->
      fields =
        cond do
          id == @key_step ->
            %{status: :active, reached_at: now}

          id in @connect_skips ->
            %{status: :skipped, reached_at: now, completed_at: now, evidence: @connect_evidence[id]}

          true ->
            %{status: :pending}
        end

      {id, fields}
    end)
  end

  # The name of the top-level stage with the lowest position that holds a flow, enabled or not.
  defp first_flow_stage(board_id) do
    board_id
    |> first_flow_stage_query()
    |> select([_f, s], s.name)
    |> Repo.one()
  end

  defp admin_rows(groups, now) do
    stages = first_flow_stages(Enum.map(groups, fn [{_step, board} | _] -> board.board_id end))

    Enum.map(groups, fn [{_step, board} | _] = steps ->
      admin_row(board, Map.new(steps, fn {step, _board} -> {step.step, step} end), stages[board.board_id], now)
    end)
  end

  # `first_flow_stage/1` for many boards in ONE query: board id => stage name.
  defp first_flow_stages(board_ids) do
    from(f in Flow,
      join: s in Stage,
      on: s.id == f.stage_id,
      where: f.board_id in ^board_ids and is_nil(s.parent_id),
      order_by: [desc: s.position, desc: s.id],
      select: {f.board_id, s.name}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp first_flow_stage_query(board_id) do
    from(f in Flow,
      join: s in Stage,
      on: s.id == f.stage_id,
      where: f.board_id == ^board_id and is_nil(s.parent_id),
      order_by: [asc: s.position, asc: s.id],
      limit: 1
    )
  end

  # No per-board default-agent lookup (a query per board): before step 2 the placeholders read
  # the default harness's LLM.
  defp admin_row(board, rows, first_flow_stage, now) do
    picked = picked_llm(rows)
    checklist = build(board.board_id, rows, picked || onboarding_llm(Agents.default_harness_key()), first_flow_stage)
    finished? = checklist.finished?
    [first | _] = checklist.steps

    top =
      if finished?,
        do: List.last(checklist.steps),
        else: Enum.find(checklist.steps, &(&1.id == checklist.current_id))

    on_step = if not finished? and top.reached_at, do: DateTime.diff(now, top.reached_at)
    stuck? = not finished? and not is_nil(on_step) and on_step > @stuck_after

    Map.merge(board, %{
      template: checklist.template,
      llm: picked && picked.label,
      current: admin_current(top, finished?),
      on_step: on_step,
      total: admin_total(first.completed_at, if(finished?, do: top.completed_at, else: now)),
      last: admin_last(checklist.steps),
      stuck?: stuck?,
      state: admin_state(finished?, stuck?),
      checklist: checklist
    })
  end

  defp admin_current(top, finished?) do
    child = if not finished?, do: Enum.find(top.children, &(&1.status in BoardSetupStep.current_statuses()))
    Map.take(child || top, [:id, :title, :status, :actor])
  end

  defp admin_total(started, ended) when is_nil(started) or is_nil(ended), do: nil
  defp admin_total(started, ended), do: DateTime.diff(ended, started)

  # Reverse catalog order: 7, 6, 5.8 … 5.1, 5, 4, 3, 2, 1.
  defp admin_last(steps) do
    steps
    |> Enum.flat_map(&[&1 | &1.children])
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{status: :failed, error: error} when is_binary(error) -> %{kind: :error, text: error}
      %{evidence: evidence} when is_binary(evidence) -> %{kind: :evidence, text: evidence}
      _entry -> nil
    end)
  end

  defp admin_state(true, _stuck?), do: :done
  defp admin_state(false, true), do: :stuck
  defp admin_state(false, false), do: :in_progress

  @doc """
  The pure, DB-free half of `checklist/1`: builds the checklist from `rows` — a map of step id to
  that step's row (a `Schemas.BoardSetupStep`, a map with `:status` and any of its other fields,
  or a bare status atom; a step with no entry is pending) — and `context`, which carries the
  `:template`, `:template_warning` and onboarding `:llm` (one of `onboarding_llms/0`), plus an
  optional `:board_id` and `:first_flow_stage` (nil when absent). `checklist/1` delegates here;
  Storybook fixtures call it directly.

  A connect (RE446) passes `connect?: true`, the `:board_name` (`%{board}`), the board's step-7
  row as `:board_claim` and the `:machine_id` (nil for an unsaved preview): each step's
  `connect_title` / `connect_why` replace its titles / why, step 7 reads
  `"board-wide · <REF> claimed <D Mon>"` (or `"board-wide · waiting for the first claim"`), and the
  tally covers steps 1–6 only — `total` 6, `position == done_count`, `finished_at` step 6's
  completion, never `closed?` and no `callout`.
  """
  @spec preview_checklist(%{optional(String.t()) => map() | atom()}, map()) :: checklist()
  def preview_checklist(rows, %{llm: llm} = context) when is_map(rows) do
    connect? = context[:connect?] == true
    rows = Map.new(@steps, &{&1.id, preview_row(Map.get(rows, &1.id))})

    fill = %{
      "%{template}" => to_string(context[:template]),
      "%{llm}" => llm.label,
      "%{cli}" => llm.cli,
      "%{skill_dir}" => to_string(llm.skill_dir),
      "%{skill_path}" => to_string(llm.skill_path),
      "%{pointer_file}" => to_string(llm.pointer_file),
      "%{board}" => to_string(context[:board_name])
    }

    children = Enum.group_by(Enum.filter(@steps, & &1.parent), & &1.parent)
    entry = &(&1 |> connect_step(connect?) |> entry(rows, fill))

    steps =
      for step <- @steps, is_nil(step.parent) do
        step
        |> entry.()
        |> Map.put(:children, Enum.map(Map.get(children, step.id, []), &(&1 |> entry.() |> Map.put(:children, []))))
      end

    steps = if connect?, do: Enum.map(steps, &board_claim_evidence(&1, context[:board_claim])), else: steps
    tally = tally(steps, connect?)
    current = Enum.find_index(tally, &(not finished_status?(&1.status)))
    current_id = current && Enum.at(tally, current).id
    done_count = Enum.count(tally, &finished_status?(&1.status))
    last = List.last(tally)
    started_at = Enum.find(steps, &(&1.id == @created_step)).completed_at
    finished_at = if finished_status?(last.status), do: last.completed_at

    %{
      board_id: context[:board_id],
      connect?: connect?,
      machine_id: context[:machine_id],
      template: context[:template],
      template_warning: context[:template_warning],
      llm: llm,
      current_id: current_id,
      current_sub_id: current_id && current_sub_id(rows, current_id),
      first_flow_stage: context[:first_flow_stage],
      position: position(connect?, current, done_count, length(tally)),
      done_count: done_count,
      finished?: is_nil(current),
      total: length(tally),
      closed?: not connect? and not is_nil(last.data["closed_at"]),
      callout: callout(last, llm, connect?),
      started_at: started_at,
      finished_at: finished_at,
      elapsed_minutes: elapsed_minutes(started_at, finished_at),
      steps: steps
    }
  end

  # A connect's tally leaves out step 7: the board's first claim, never a machine's.
  defp tally(steps, true = _connect?), do: Enum.reject(steps, &(&1.id == @claim_step))
  defp tally(steps, false), do: steps

  defp elapsed_minutes(%DateTime{} = started_at, %DateTime{} = finished_at),
    do: DateTime.diff(finished_at, started_at, :minute)

  defp elapsed_minutes(_started_at, _finished_at), do: nil

  defp position(true = _connect?, _current, done_count, _total), do: done_count
  defp position(false, nil, _done_count, total), do: total
  defp position(false, current, _done_count, _total), do: current + 1

  # On a connect a step's `connect_title` replaces its title and done title, its `connect_why` its why.
  defp connect_step(step, false), do: step

  defp connect_step(step, true) do
    step = if step.connect_title, do: %{step | title: step.connect_title, done_title: step.connect_title}, else: step
    if step.connect_why, do: %{step | why: step.connect_why}, else: step
  end

  defp board_claim_evidence(%{id: @claim_step} = entry, board_claim),
    do: %{entry | evidence: "board-wide · " <> board_claim_text(board_claim)}

  defp board_claim_evidence(entry, _board_claim), do: entry

  defp board_claim_text(%{status: :done, completed_at: %DateTime{} = at, data: %{"card_ref" => ref}}),
    do: "#{ref} claimed #{Calendar.strftime(at, "%-d %b")}"

  defp board_claim_text(_board_claim), do: "waiting for the first claim"

  # The payoff callout: only once step 7 is done with a claimed card and not yet dismissed.
  defp callout(%{status: :done, data: %{"card_ref" => ref} = data}, llm, false = _connect?)
       when not is_map_key(data, "callout_dismissed_at") do
    %{card_ref: ref, card_id: data["card_id"], machine: data["machine"], llm: llm.label, verb: data["verb"]}
  end

  defp callout(_claimed, _llm, _connect?), do: nil

  @blank_row %{status: :pending, reached_at: nil, completed_at: nil, evidence: nil, error: nil, data: %{}}

  defp preview_row(nil), do: @blank_row
  defp preview_row(status) when is_atom(status), do: %{@blank_row | status: status}
  defp preview_row(%BoardSetupStep{} = row), do: row
  defp preview_row(%{} = row), do: Map.merge(@blank_row, row)

  # Step 2's pick, else the board default agent's harness, else claude-code.
  defp checklist_llm(board_id, rows) do
    picked_llm(rows) ||
      onboarding_llm(with(%{harness: %{key: key}} <- Agents.default_agent(board_id), do: key)) ||
      onboarding_llm(Agents.default_harness_key())
  end

  defp picked_llm(rows), do: onboarding_llm(rows[@llm_step] && rows[@llm_step].data["llm"])

  defp entry(step, rows, fill) do
    row = rows[step.id]
    title = if row.status == :done && step.done_title, do: step.done_title, else: step.title

    Map.merge(step, %{
      title: resolve(title, fill),
      done_title: resolve(step.done_title, fill),
      connect_title: resolve(step.connect_title, fill),
      why: resolve(step.why, fill),
      what_this_does: Enum.map(step.what_this_does, &resolve(&1, fill)),
      status: row.status,
      reached_at: row.reached_at,
      completed_at: row.completed_at,
      evidence: row.evidence,
      error: row.error,
      data: row.data
    })
  end

  defp resolve(nil, _fill), do: nil

  defp resolve(text, fill) do
    Enum.reduce(fill, text, fn {placeholder, value}, acc -> String.replace(acc, placeholder, value) end)
  end

  defp finished_status?(status), do: status in BoardSetupStep.finished_statuses()

  defp hhmm(at), do: Calendar.strftime(at, "%H:%M")

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp board_id(%Board{id: id}), do: id
  defp board_id(id) when is_integer(id), do: id
end
