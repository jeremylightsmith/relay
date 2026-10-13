defmodule Relay.Setup do
  @moduledoc """
  The Setup context (RE443): a board's **setup checklist** — the guided path from "board created
  from a template" to "an agent picked up the first card".

  This module owns the step **catalog** (`steps/0`), the ONE list of step ids, titles, actors,
  *why* and *what this does* lines; every surface renders from it through `checklist/1`, the only
  place the `%{template}`, `%{llm}`, `%{skill_path}` and `%{pointer_file}` placeholders resolve.
  It also owns the onboarding LLMs (`onboarding_llms/0`) step 2 offers.

  Storage is one `Schemas.BoardSetupStep` row per `(board, catalog id)`, inserted by `start/2`
  from `Relay.Boards.create_board/2` on the template path only — a board with no rows has no
  checklist. `advance/4` moves it strictly in order: only the current step (the first top-level
  step not in `Schemas.BoardSetupStep.finished_statuses/0`) may change. Every change broadcasts
  `{:setup_changed, board_id}` through `Relay.Events.broadcast/2`.

  `choose_llm/3` (step 2) sets the board's default agent and mints the step-3 board key;
  `remint_key/2` replaces it. The raw token is returned to the caller once and never stored.

  The install handshake (`GET /b/:slug/install`) reports through `preflight/2` and `installed/2`:
  the key's first authed call ticks step 3, the preflight result marks step 4 waiting or failed
  (with the fix text from `preflight_checks/0`'s catalog), and the written files finish step 4.

  `Relay.Boards` depends on this context, so this one never calls `Relay.Boards` or
  `Relay.Flows`: it counts stages and flows with `Relay.Repo` queries.
  """

  use Boundary, deps: [Relay.Agents, Relay.ApiKeys, Relay.Events, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Agents
  alias Relay.ApiKeys
  alias Relay.Events
  alias Relay.Repo
  alias Schemas.ApiKey
  alias Schemas.Board
  alias Schemas.BoardSetupStep
  alias Schemas.Flow
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
          read_only_note: String.t() | nil
        }

  @type llm :: %{
          harness: String.t(),
          label: String.t(),
          cli: String.t(),
          blurb: String.t(),
          install: String.t() | nil,
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
          template: String.t(),
          template_warning: String.t() | nil,
          llm: llm(),
          current_id: String.t() | nil,
          position: 1..7,
          done_count: 0..7,
          finished?: boolean(),
          steps: [entry()]
        }

  @actors [:you_here, :you_terminal, :ai_terminal]

  @step_blank %{parent: nil, done_title: nil, why: nil, what_this_does: [], read_only_note: nil}

  @onboard_children [
    {"5.1", "Pull the board's flows into .relay/flows/"},
    {"5.2", "Detect your repo, then confirm what was found"},
    {"5.3", "Interview: what the repo can't answer"},
    {"5.4", "Customize flows, runner.json and the warm-up hook"},
    {"5.5", "Push flows back (enabled on arrival)"},
    {"5.6", "Relay files on origin/main"},
    {"5.7", "Follow-up cards tagged #setup"},
    {"5.8", "Your first card"}
  ]

  # The ONE step catalog, in catalog order 1, 2, 3, 4, 5, 5.1 … 5.8, 6, 7.
  @steps Enum.map(
           [
             %{
               id: "1",
               title: "Board created",
               done_title: "Board created from %{template}",
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
               actor: :you_terminal,
               why:
                 "Puts the runner and the onboarding skill in your repo. It's a script you run, not a file you set up.",
               what_this_does: [
                 "./relay — the runner and CLI, with this board's URL baked in",
                 "%{skill_path} — the onboarding skill",
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
               actor: :ai_terminal,
               why:
                 "%{llm} reads this checklist and works it top to bottom in your terminal, asking you only what it can't see.",
               what_this_does: ["Run /relay-onboard in your repo; it works sub-steps 5.1–5.8 below."]
             }
           ] ++
             Enum.map(@onboard_children, fn {id, title} -> %{id: id, parent: "5", title: title, actor: :ai_terminal} end) ++
             [
               %{
                 id: "6",
                 title: "Start the runner",
                 actor: :you_terminal,
                 why: "The runner is what actually picks up cards. Give it its own terminal and leave it running.",
                 what_this_does: ["Run ./relay start in its own terminal. This ticks on the runner's first heartbeat."]
               },
               %{
                 id: "7",
                 title: "Watch an agent pick up your first card",
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

  # The steps this context drives itself: step 1 (start), step 2 (choose_llm), step 3 (the key),
  # step 4 (the install handshake).
  @created_step Enum.at(@top_ids, 0)
  @llm_step Enum.at(@top_ids, 1)
  @key_step Enum.at(@top_ids, 2)
  @install_step Enum.at(@top_ids, 3)
  @onboard_step Enum.at(@top_ids, 4)

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
  # This map is the only place the per-CLI skill directory and pointer file are written.
  @llm_facts %{
    "claude-code" => %{
      cli: "claude",
      blurb: "Recommended. Best tested with Relay's flows.",
      install: "npm install -g @anthropic-ai/claude-code",
      skill_path: ".claude/skills/relay-onboard/SKILL.md",
      pointer_file: "CLAUDE.md",
      recommended?: true,
      enabled?: true
    },
    "codex" => %{
      cli: "codex",
      blurb: "OpenAI's CLI.",
      install: "npm install -g @openai/codex",
      skill_path: ".agents/skills/relay-onboard/SKILL.md",
      pointer_file: "AGENTS.md",
      recommended?: false,
      enabled?: true
    },
    "gemini-cli" => %{
      cli: "gemini",
      blurb: "Google's CLI.",
      install: nil,
      skill_path: nil,
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
  Strings may hold `%{template}`, `%{llm}`, `%{skill_path}` and `%{pointer_file}`, resolved only by
  `checklist/1`.
  """
  @spec steps() :: [step()]
  def steps, do: @steps

  @doc """
  The catalog id of the step that plays `role`: `:llm` (step 2's pick), `:key` (step 3's board
  key), `:install` (step 4's install script) or `:onboard` (step 5, with its sub-steps). Surfaces
  that render a step differently (the wizard's LLM picker, key box, install command) branch on
  this rather than re-typing an id.
  """
  @spec step_id(:llm | :key | :install | :onboard) :: String.t()
  def step_id(:llm), do: @llm_step
  def step_id(:key), do: @key_step
  def step_id(:install), do: @install_step
  def step_id(:onboard), do: @onboard_step

  @doc "The LLMs step 2 offers, in seed-harness order: Claude Code, Codex, Gemini CLI."
  @spec onboarding_llms() :: [llm()]
  def onboarding_llms do
    for %{key: key, name: name} <- Agents.seed_harnesses(), facts = @llm_facts[key], not is_nil(facts) do
      Map.merge(%{harness: key, label: name}, facts)
    end
  end

  @doc "The onboarding LLM for a harness key, or nil."
  @spec onboarding_llm(String.t() | nil) :: llm() | nil
  def onboarding_llm(harness_key), do: Enum.find(onboarding_llms(), &(&1.harness == harness_key))

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
  checklist it ticks step 3 (the key's first authed call) and marks step 4 `:waiting` or `:failed`;
  a step already past is left alone. Refuses a key from another board (`:wrong_board`), a board
  still on step 1–2 (`:step_2_pending`) and a malformed request (`:invalid`), writing nothing.
  """
  @spec preflight(ApiKey.t(), map()) :: {:ok, map()} | {:error, :wrong_board | :step_2_pending | :invalid}
  def preflight(%ApiKey{board: %Board{} = board} = key, params) when is_map(params) do
    with {:ok, req} <- parse_preflight(params),
         :ok <- same_board(board, req.slug),
         {:ok, current_id} <- preflight_step(board) do
      llm = install_llm(board.id)
      checks = local_checks(req.checks) ++ [cli_check(llm, req.clis), key_check(key)]
      failed = Enum.find(checks, &(not &1["ok"]))
      failure = failure(failed, llm)

      record_preflight(board, current_id, %{key: key, machine: req.machine, checks: checks, failed: failed}, failure)

      {:ok,
       Map.merge(
         %{
           ok: is_nil(failed),
           board: board.name,
           llm: Map.take(llm, [:harness, :label, :cli, :skill_path, :pointer_file]),
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
  def installed(%ApiKey{board: %Board{} = board}, params) when is_map(params) do
    with {:ok, req} <- parse_installed(params),
         :ok <- same_board(board, req.slug) do
      with %{id: @install_step} <- current(board) do
        advance(board, @install_step, :done, %{
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

  # The step a preflight reports into: nil when the board has no checklist (or it is finished).
  defp preflight_step(board) do
    case current(board) do
      nil -> {:ok, nil}
      %{id: id} when id in [@created_step, @llm_step] -> {:error, :step_2_pending}
      %{id: id} -> {:ok, id}
    end
  end

  # The checklist's onboarding LLM; a board with no checklist uses its default agent's. A disabled
  # LLM can't be installed, so it falls back to the default harness's.
  defp install_llm(board_id) do
    rows = Map.new(Repo.all(from(s in BoardSetupStep, where: s.board_id == ^board_id)), &{&1.step, &1})

    case checklist_llm(board_id, rows) do
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
  defp record_preflight(board, @key_step, result, failure) do
    _ =
      advance(board, @key_step, :done, %{
        evidence: "first authed call #{hhmm(now())} · key …#{result.key.last_four} · #{result.machine}"
      })

    record_preflight(board, @install_step, result, failure)
  end

  defp record_preflight(board, @install_step, %{failed: nil} = result, _failure) do
    advance(board, @install_step, :waiting, %{
      evidence: "preflight passed #{hhmm(now())} · #{result.machine}",
      data: %{"checks" => result.checks}
    })
  end

  defp record_preflight(board, @install_step, %{failed: failed} = result, failure) do
    detail = if String.trim(failed["detail"]) == "", do: failed["label"], else: failed["detail"]

    advance(board, @install_step, :failed, %{
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

  defp record_preflight(_board, _step_id, _result, _failure), do: :ok

  # ---------------------------------------------------------------- checklist

  @doc """
  Starts the board's checklist: one row per catalog id. Step 1 is done (its evidence counts the
  board's top-level stages and flows; its data carries the template's name and warning), step 2
  is active, the rest are pending. Runs inside `create_board`'s transaction, so it raises on
  failure. Broadcasts `{:setup_changed, board_id}` once.
  """
  @spec start(Board.t(), %{
          required(:name) => String.t(),
          optional(:warning) => String.t() | nil,
          optional(atom()) => any()
        }) ::
          :ok
  def start(%Board{id: board_id}, template) do
    now = now()
    stages = Repo.aggregate(from(s in Stage, where: s.board_id == ^board_id and is_nil(s.parent_id)), :count)
    flows = Repo.aggregate(from(f in Flow, where: f.board_id == ^board_id), :count)

    created = %{
      status: :done,
      reached_at: now,
      completed_at: now,
      evidence: "#{stages} stages · #{flows} flows · #{hhmm(now)}",
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

  @doc """
  The board's checklist, every placeholder resolved: its template, the onboarding LLM, where it
  stands (`current_id`, `position`, `done_count`, `finished?`) and the 7 top-level entries (step
  5's sub-steps in its `children`). nil when the board has no checklist.
  """
  @spec checklist(Board.t() | integer()) :: checklist() | nil
  def checklist(board) do
    board_id = board_id(board)

    case Repo.all(from(s in BoardSetupStep, where: s.board_id == ^board_id)) do
      [] -> nil
      rows -> build(board_id, Map.new(rows, &{&1.step, &1}))
    end
  end

  @doc "The step the checklist is on: the first top-level entry not finished, or nil."
  @spec current(Board.t() | integer()) :: entry() | nil
  def current(board) do
    case checklist(board) do
      nil -> nil
      %{steps: steps} -> Enum.find(steps, &(not finished_status?(&1.status)))
    end
  end

  @doc """
  Moves the current top-level step to `status` (`:waiting | :done | :failed | :skipped`). `attrs`
  may carry `evidence`, `error` (kept only for `:failed`) and `data` (merged into the row's data),
  with atom or string keys. `:done` / `:skipped` complete the step and activate the next one. A
  repeat that would change nothing returns `{:ok, checklist}` without writing or broadcasting —
  including the repeat of the transition that just finished the step. Any change broadcasts
  `{:setup_changed, board_id}` once. Serialized on the board row.
  """
  @spec advance(Board.t() | integer(), String.t(), atom(), map()) ::
          {:ok, checklist()} | {:error, :not_current | :no_checklist | :invalid_status}
  def advance(board, step_id, status, attrs) when is_binary(step_id) and is_map(attrs) do
    if status in @advance_statuses,
      do: Repo.transact(fn -> locked_advance(board_id(board), step_id, status, attrs) end),
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
      with {:ok, rows} <- lock_current(board.id, @llm_step),
           {:ok, llm} <- enabled_llm(harness_key) do
        :ok = make_default!(board, llm)

        :ok =
          apply_advance(rows, @llm_step, :done, %{
            evidence: "chosen #{hhmm(now())} · change in Settings",
            data: %{"llm" => llm.harness}
          })

        # step 2's advance above already queued the one broadcast for this change
        token = mint_key!(board, user)
        {:ok, %{checklist: checklist(board.id), token: token}}
      end
    end)
  end

  @doc """
  Step 3: mints a fresh board key in `user`'s name and points step 3 at it. The previous setup key
  is revoked when it was never used; a key a runner already used stays. Returns the raw token once.
  """
  @spec remint_key(Board.t(), User.t()) :: {:ok, %{checklist: checklist(), token: String.t()}} | {:error, :not_current}
  def remint_key(%Board{} = board, %User{} = user) do
    Repo.transact(fn ->
      with {:ok, rows} <- lock_current(board.id, @key_step) do
        :ok = revoke_unused_key(board, rows[@key_step])
        token = mint_key!(board, user)
        :ok = Events.broadcast(board.id, {:setup_changed, board.id})
        {:ok, %{checklist: checklist(board.id), token: token}}
      end
    end)
  end

  # ---------------------------------------------------------------- internals

  # Like `Agents.ensure_seeded!/1`: lock the board row so two callers can't both advance.
  defp lock(board_id) do
    _ = Repo.one(from(b in Board, where: b.id == ^board_id, select: b.id, lock: "FOR UPDATE"))

    case Repo.all(from(s in BoardSetupStep, where: s.board_id == ^board_id)) do
      [] -> {:error, :no_checklist}
      rows -> {:ok, Map.new(rows, &{&1.step, &1})}
    end
  end

  defp lock_current(board_id, step_id) do
    with {:ok, rows} <- lock(board_id),
         ^step_id <- current_id(rows) do
      {:ok, rows}
    else
      _ -> {:error, :not_current}
    end
  end

  defp locked_advance(board_id, step_id, status, attrs) do
    with {:ok, rows} <- lock(board_id),
         :ok <- apply_advance(rows, step_id, status, attrs) do
      {:ok, checklist(board_id)}
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

    cond do
      unchanged?(row, change) -> :ok
      current_id(rows) != step_id -> {:error, :not_current}
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

    if finishing?, do: activate_next!(rows, row.step, now)
    Events.broadcast(row.board_id, {:setup_changed, row.board_id})
  end

  defp activate_next!(rows, step_id, now) do
    next =
      @top_ids
      |> Enum.drop_while(&(&1 != step_id))
      |> Enum.find(&(rows[&1].status == :pending))

    if next, do: rows[next] |> Ecto.Changeset.change(status: :active, reached_at: now) |> Repo.update!()
  end

  defp current_id(rows), do: Enum.find(@top_ids, &(not finished_status?(rows[&1].status)))

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

  defp mint_key!(board, user) do
    {:ok, %{api_key: api_key, token: token}} = ApiKeys.create_key(board, user, key_name(user))
    row = Repo.get_by!(BoardSetupStep, board_id: board.id, step: @key_step)

    row
    |> Ecto.Changeset.change(data: Map.put(row.data, "key_id", api_key.id))
    |> Repo.update!()

    token
  end

  defp key_name(user), do: String.slice("Setup · #{user.name || user.email}", 0, ApiKey.name_max_length())

  defp revoke_unused_key(board, row) do
    with id when not is_nil(id) <- row.data["key_id"],
         %ApiKey{last_used_at: nil} = key <- Repo.get_by(ApiKey, id: id, board_id: board.id) do
      {:ok, _} = ApiKeys.revoke(key)
    end

    :ok
  end

  defp build(board_id, rows) do
    created = rows[@created_step]

    preview_checklist(rows, %{
      board_id: board_id,
      template: created && created.data["template"],
      template_warning: created && created.data["template_warning"],
      llm: checklist_llm(board_id, rows)
    })
  end

  @doc """
  The pure, DB-free half of `checklist/1`: builds the checklist from `rows` — a map of step id to
  that step's row (a `Schemas.BoardSetupStep`, a map with `:status` and any of its other fields,
  or a bare status atom; a step with no entry is pending) — and `context`, which carries the
  `:template`, `:template_warning` and onboarding `:llm` (one of `onboarding_llms/0`), plus an
  optional `:board_id`. `checklist/1` delegates here; Storybook fixtures call it directly.
  """
  @spec preview_checklist(%{optional(String.t()) => map() | atom()}, map()) :: checklist()
  def preview_checklist(rows, %{llm: llm} = context) when is_map(rows) do
    rows = Map.new(@steps, &{&1.id, preview_row(Map.get(rows, &1.id))})

    fill = %{
      "%{template}" => to_string(context[:template]),
      "%{llm}" => llm.label,
      "%{skill_path}" => to_string(llm.skill_path),
      "%{pointer_file}" => to_string(llm.pointer_file)
    }

    children = Enum.group_by(Enum.filter(@steps, & &1.parent), & &1.parent)

    steps =
      for step <- @steps, is_nil(step.parent) do
        step
        |> entry(rows, fill)
        |> Map.put(
          :children,
          Enum.map(Map.get(children, step.id, []), &(&1 |> entry(rows, fill) |> Map.put(:children, [])))
        )
      end

    current = Enum.find_index(steps, &(not finished_status?(&1.status)))
    done_count = Enum.count(steps, &finished_status?(&1.status))

    %{
      board_id: context[:board_id],
      template: context[:template],
      template_warning: context[:template_warning],
      llm: llm,
      current_id: current && Enum.at(steps, current).id,
      position: if(current, do: current + 1, else: length(steps)),
      done_count: done_count,
      finished?: is_nil(current),
      steps: steps
    }
  end

  @blank_row %{status: :pending, reached_at: nil, completed_at: nil, evidence: nil, error: nil, data: %{}}

  defp preview_row(nil), do: @blank_row
  defp preview_row(status) when is_atom(status), do: %{@blank_row | status: status}
  defp preview_row(%BoardSetupStep{} = row), do: row
  defp preview_row(%{} = row), do: Map.merge(@blank_row, row)

  # Step 2's pick, else the board default agent's harness, else claude-code.
  defp checklist_llm(board_id, rows) do
    picked = rows[@llm_step] && rows[@llm_step].data["llm"]

    onboarding_llm(picked) ||
      onboarding_llm(with(%{harness: %{key: key}} <- Agents.default_agent(board_id), do: key)) ||
      onboarding_llm(Agents.default_harness_key())
  end

  defp entry(step, rows, fill) do
    row = rows[step.id]
    title = if row.status == :done && step.done_title, do: step.done_title, else: step.title

    Map.merge(step, %{
      title: resolve(title, fill),
      done_title: resolve(step.done_title, fill),
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
