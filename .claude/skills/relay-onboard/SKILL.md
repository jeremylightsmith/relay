---
name: relay-onboard
description: Use when wiring a repo to a Relay board for the first time — after the board's install script has run — to work step 5 of the board's guided-setup checklist (sub-steps 5.1–5.8: pull the flows, detect the repo, interview, customize, push, land the files, follow-ups, first card) as a resumable loop through `./relay setup status` and `./relay setup report`. Keywords: onboard, wire up, set up Relay, new project, guided setup, setup checklist, step 5, project.md.
---

# Relay Onboard

## Overview

Onboarding is **a loop over the board's setup checklist**. The board keeps the checklist; you
read it, do the first sub-step that isn't done, report it, and read it again:

    loop: ./relay setup status → first unmet sub-step → say what you'll do → do it
          → ./relay setup report → re-read status

The board is the oracle — it never hands out steps, it only says what is done. Every report
updates the board's setup wizard live, so the human can watch from the browser.

**Plain chat.** Talk like a person in the terminal: no boxes, menus, tables or progress bars.
Before each sub-step, say what you are about to do, using the checklist's numbers (5.1–5.8).
Ask **one question at a time**, and "skip" always works.

**Never run this from a flow node.** It asks the human questions; a flow node has nobody to
answer.

**Blast radius:** Relay's own files only — `./relay`, the onboarding skill file(s), `relay.md`
and the one pointer line in your LLM's convention file, `.gitignore`, everything under
`.relay/` (flows, `runner.json`, `prepare-worktree.sh`, `project.md`) — plus the board's flows
and the cards made in 5.7–5.8. On a copied board, 5.4 may also write the missing
`.claude/agents/*.md`, `.claude/skills/*/SKILL.md` and `.claude/commands/*.md` files that the
board's flows name. It **never touches app code**: no source, tests, config or
dependencies of the project itself. If a fix seems to need app code, it becomes a `#setup card`
instead.

**Say "your LLM", never a product name.** This skill is shared by every supported coding
agent, so it names none of them.

## Start / resume

Run `./relay setup status --json` and read the exit code first.

- **Exit code 3** — the board has no checklist. Print exactly
  *"This board predates guided setup; use /relay-doctor."* and stop. Write nothing.
- **`current_id` is before 5** (the board, LLM, key or install step is still pending) — say
  which step is pending and what the human does there (on the board, or by running the install
  script), then stop.
- **`finished` is true, or `current_id` is 6 or 7** — onboarding is done; go to **Close**.
- **Otherwise** announce:
  *"Setup checklist for <board>: <done_count> of 7 done. Next is <current>, <what it does>."*
  and work from `current_sub_id`.

Never redo a sub-step that is already `done` or `skipped`. Interrupting is safe at any point:
running `/relay-onboard` again resumes at the first unmet sub-step.

The status JSON carries what the loop needs: `board`, `connect`, `template`, `llm` (`harness`,
`label`, `cli`, `skill_dir`, `skill_path`, `pointer_file`), `current_id`, `current_sub_id`, `current`, `first_flow_stage`,
`done_count`, `finished`, `interview` (`[{id, label, question}]`), `change_decisions`,
`referenced_files` (`[{kind, name, paths, used_by: [{flow, node}]}]`, the agent and skill files
the board's flows name), `missing_file_resolutions`, and `steps` (each with `id`, `title`,
`status`, `evidence`, `error`, `data`, `children`).

## Connecting another machine

When status says `"connect": true`, this key belongs to a person's **own machine** on a board
that is already set up: the board-wide steps and the interview, customize, push-back, follow-up
and first-card sub-steps are already `skipped`. Only 5.1 and 5.6 are left.

- Announce *"Setup checklist for <board>: <done_count> of 6 done. Next is <current>, <what it
  does>."*
- Do **5.1** exactly as written.
- At **5.6**, do **not** commit, push or open a PR. `git fetch`, then check that every
  Relay-owned file exists on origin/<base> — `relay`, `relay.md`, `.relay/scaffold.json`,
  `<llm.skill_dir>/relay-onboard/SKILL.md`, `<llm.skill_dir>/relay-update/SKILL.md` and
  `<llm.skill_dir>/relay-doctor/SKILL.md` (status `llm.skill_dir`) — with
  `git cat-file -e origin/<base>:<path>` for **each** of the six. If they all do:

      ./relay setup report 5.6 --status done --evidence "origin/<base> has the Relay files"

  Otherwise:

      ./relay setup report 5.6 --status failed --error "The Relay files aren't on origin/<base> yet. Finish onboarding on the first machine, then run /relay-onboard again."

Then go to **Close**.

## The loop

1. `./relay setup status --json` → find the current sub-step (`current_sub_id`).
2. Say what you are about to do.
3. Do it (the sections below).
4. Report it:

       ./relay setup report <step> --status waiting|done|failed|skipped \
         [--evidence TEXT] [--error TEXT] [--data JSON|@path]

5. Re-read status and continue.

Only the current sub-step can be reported. A report out of order exits 1 with `not_current`
and names the current step on stderr — re-read status and carry on from the step the board
names. Re-reporting a step that already finished is a harmless no-op.

## When a step won't go green

Diagnose on this machine, fix the cause, retry — **at most 3 attempts**. Say each attempt as it
happens ("Rejected (1/3): …, retrying"). After the 3rd failure:

1. Report it failed:

       ./relay setup report <step> --status failed --error "<last error>" \
         --evidence "<short what> · attempt 3/3" --data '{"attempts": 3}'

2. Tell the human you are stuck on that step, what you tried, and offer concrete options:
   **(a) show the diff** of what you changed, **(b) reset and redo** the step (and the step it
   depends on, if that is the cause), or **(c) skip it and make a #setup card** — report the
   step `skipped` and create a Backlog card with `--tag setup` describing what is left.

Never mark a step done that isn't.

## 5.1 Pull the flows

Say you are pulling the board's flows. List them with `./relay flow`, then for each key write
`./relay flow <key> --json` to `.relay/flows/<key>.json`.

Then check the files the flows name: status `referenced_files`. An entry is **missing** when
none of its `paths` exists in this repo (a skill is there if either of its paths is). A board
copied from another board's flows can name files that only live in that board's repo.

If nothing is missing — always the case on a template board — say nothing extra and report:

    ./relay setup report 5.1 --status done --evidence "<N> flows"

If some are missing, list them by name in one message — "This board's flows name <M> files that
aren't in this repo: <names>; we'll sort each one out at 5.4" — and report them, each entry as
`referenced_files` has it:

    ./relay setup report 5.1 --status done --evidence "<N> flows · <M> missing files" \
      --data '{"missing_files": [{"kind": "agent", "name": "plan-implementer", "paths": [".claude/agents/plan-implementer.md"], "used_by": [{"flow": "code", "node": "implement"}]}]}'

## 5.2 Detect, then confirm

Say you'll read the repo and tell the human what you found. Work out: the stack and versions;
the test, lint and build commands; the one "all green" command; the base branch; CI; and the
convention files (`AGENTS.md`, the pointer file and similar — flow prompts will point at them).
Send **one** message: "Here's what I found. Correct anything that's wrong:" with that list.
Apply corrections, then report:

    ./relay setup report 5.2 --status done --evidence "<stack> · <green command>"

## 5.3 Interview → .relay/project.md

Ask only what the repo can't answer. The questions come from status `interview`, in order —
ids `done`, `landing`, `deploy`, `baton`, `ui`, `never_touch`, `warm_up`, `capacity`,
`misfits`. Say how many there are, that answers go to `.relay/project.md` (flow prompts read
it; 5.6 commits it) plus a copy on the board, and that "skip" keeps the default.

Ask them **one at a time** ("1/9 <question>"). Sharpen a question with what you found in 5.2
(e.g. the dev server and port for `ui`, the measured cold build time for `warm_up`). "skip"
records the default as the answer.

After **each** answer, report every answer so far (the whole map, every time):

    ./relay setup report 5.3 --status waiting --data '{"answers": {"done": "merged", "landing": "PR"}}'

At the end write `.relay/project.md` in this format — a title, then one section per question
in catalog order, its `label` as the heading, the question on one italic line, the answer
beneath it:

    # <board> — project notes for Relay

    ## Done means
    *What does "done" mean for a card: a PR opened, merged, or deployed?*
    merged

    ## Changes land
    …

Then report done with the final answers:

    ./relay setup report 5.3 --status done --evidence "9 of 9 answered" --data '{"answers": {…}}'

## 5.4 Customize: propose, agree one by one, apply

### First, the missing files (copied boards only)

When 5.1's `data` has a non-empty `missing_files`, resolve each one **before** the regular
proposals. Otherwise skip this part and say nothing about it.

Step 1's `evidence` reads `copied from <source>` on a copied board. Say *"Before the changes:
this board was copied from <source>, and its flows name <N> files that aren't in this repo:"*
followed by the first few names (end with `…` when there are more). If step 1's evidence doesn't
start with `copied from`, say *"this board's flows name <N> files that aren't in this repo"*
instead. Then give the options, one line each (status `missing_file_resolutions`):

- `stub` — write a minimal file for you to fill in later
- `inline` — write the prompt into the flow node itself
- `drop` — remove the node (I'll tell you what it rewires)
- *"Or give me a path to the real file if you have it locally."* (`path`)

Ask about **one file at a time**: `k/N  <name> (used by <flow> › <node>)?`, listing every
`used_by` pair joined with `, `.

Apply each answer **as it is given** — this walk is the exception to "nothing changes until
every proposal is decided":

- `stub` — an agent gets `.claude/agents/<name>.md` with frontmatter `name` and `description`
  and a one-line TODO body; a skill gets `.claude/skills/<name>/SKILL.md` with `name` and
  `description`.
- `inline` — in `.relay/flows/<flow>.json`, clear the node's `agent` and set its `run` to the
  prompt: the agent file's body if the human pastes it, otherwise a short prompt you write and
  show.
- `drop` — remove the node from `.relay/flows/<flow>.json` and point its incoming edges at its
  `succeeded` target. Say what it rewired.
- `path` — copy the file from that local path to the entry's first `paths` entry, and say
  *"Copied it from there."* If the path doesn't exist, say *"<path> doesn't exist. Try another
  path, or stub / inline / drop."* and ask about the **same** file again.

Report when the walk starts and after each answer, sending the whole list every time — each
entry as 5.1 had it plus its `resolution` (`null` until answered) and `source` (the local path
for `path`, otherwise `null`):

    ./relay setup report 5.4 --status waiting --evidence "missing files k of N resolved" \
      --data '{"missing_files": [{"kind": "agent", "name": "plan-implementer", "paths": [".claude/agents/plan-implementer.md"], "used_by": [{"flow": "code", "node": "implement"}], "resolution": "path", "source": "~/src/relay/.claude/agents/plan-implementer.md"}]}'

Keep the final `missing_files` list in 5.4's `data` from then on, next to `changes`.

### Then, the proposals

From the answers and what you detected, list **every** proposed change up front, numbered.
Candidates:

- flow commands and nodes (e.g. the validate command → the "all green" command; drop the
  screenshot and smoke nodes when there is no UI);
- `.relay/runner.json` — `capacity`, from the `capacity` answer (how much of the LLM plan
  Relay may use is set per harness on the board — say so);
- the `WARM=""` list in `.relay/prepare-worktree.sh`, from the `warm_up` answer;
- pointers to `.relay/project.md` (and the never-touch list) in flow prompts.

Say you'll go through them one at a time and change **nothing** until every one is decided.
Report the whole list, each `pending`:

    ./relay setup report 5.4 --status waiting \
      --data '{"changes": [{"summary": "validate: `mix test` → `mix precommit`", "decision": "pending", "note": null}]}'

(On a copied board, send `missing_files` alongside `changes` in every 5.4 report.)

Then for each change in turn: mark it `asking` and report the whole list, ask "(yes / no /
edit)", record the answer as `accepted`, `rejected` or `edited` (an edit's wording goes in
`note`), and report the whole list again. Wrap commands and paths in backticks in `summary`.

Nothing on disk changes before the last decision — `git status` stays as it was (apart from the
missing files already resolved above). Then say you are about to write, apply **only** the
accepted and edited changes, and report:

    ./relay setup report 5.4 --status done --evidence "<short summary, e.g. dropped screenshots>" \
      --data '{"changes": [ …every change with its final decision… ], "missing_files": [ … ]}'

## 5.5 Push the flows back, enabled

Set `"enabled": true` in each `.relay/flows/<key>.json`, then push each one:

    ./relay flow-push <key> .relay/flows/<key>.json

Re-read status — the board ticks 5.5 itself once every board flow has arrived enabled. Say
"Pushed <N> flows; they're enabled." A rejected push (e.g. a 422 naming a node) is a step that
won't go green: fix the flow file and retry, at most 3 attempts.

## 5.6 Relay files on origin/<base>

Say *"The runner can't work until these changes are on origin/<base>."* Commit everything Relay
wrote — the Relay-owned files `./relay`, `relay.md`, `.relay/scaffold.json` and the three skills
`<llm.skill_dir>/relay-onboard/SKILL.md`, `<llm.skill_dir>/relay-update/SKILL.md` and
`<llm.skill_dir>/relay-doctor/SKILL.md` (status `llm.skill_dir`); the pointer-file line (status
`llm.pointer_file`), `.gitignore`, `.relay/` including `.relay/project.md`; and any `.claude/agents/*.md`,
`.claude/skills/*/SKILL.md` or `.claude/commands/*.md` file 5.4 wrote for a missing file — and
**nothing else** (stage those
paths by name; leave any other change in the tree alone). Then land it the way the `landing`
answer says: push straight to `<base>`, or push a branch and open a PR.

While it isn't on origin/<base> yet, report waiting with the PR and base:

    ./relay setup report 5.6 --status waiting --evidence "PR #<n> open · checked HH:MM" \
      --data '{"pr_url": "https://…/pull/<n>", "base": "<base>"}'

Then `git fetch` every 30 s. It is done when origin/<base> contains the commit, **or** every
file the commit touched is identical on origin/<base> (a squash or rebase merge never contains
the commit itself):

    git merge-base --is-ancestor <sha> origin/<base> \
      || git diff --quiet <sha> origin/<base> -- $(git diff-tree --no-commit-id --name-only -r <sha>)

Say that Ctrl-C is safe: running `/relay-onboard` again picks up here. When it lands:

    ./relay setup report 5.6 --status done --evidence "origin/<base> contains <short sha>"

## 5.7 Follow-up cards #setup

Everything deferred or left unresolved along the way (a rejected change worth revisiting, an
unanswered question, a skipped step) becomes a Backlog card tagged `setup`:

    ./relay create "<title>" --stage Backlog --tag setup --description "<what is left and why>"

(If the board names its first stage something other than Backlog, pass that stage instead.)
List the cards you made, then report:

    ./relay setup report 5.7 --status done --evidence "<N> #setup cards"

(evidence `"none"` when there was nothing to defer).

## 5.8 First card

Suggest 2–3 small, concrete improvements for this repo (a file or two each), numbered. The
human picks one or types their own. Create it in the board's first flow stage (status
`first_flow_stage`):

    ./relay create "<title>" --stage <first_flow_stage> --description "<what and why>"

Re-read status — the board ticks 5.8 itself when the card lands.

## Close

Say that everything but the runner is done, then: *"In a new terminal, run ./relay start"* —
and that the first card turns violet on the board when an agent picks it up. Exit.

## Common mistakes

- **Redoing finished sub-steps.** Always start from status; a re-run resumes, it never restarts.
- **Listing proposals before the missing files.** On a copied board 5.4 resolves each missing
  file first.
- **Writing during 5.4's agreement.** No file — flows, `runner.json`, the warm-up hook, prompt
  pointers — changes until the last change is decided (the missing-files walk excepted).
- **Reporting a partial list.** 5.3 sends all answers so far; 5.4 sends the whole change list.
- **Committing more than Relay's files in 5.6.** Stage paths by name; app code is never part of
  it.
- **Looping on a broken step.** Three attempts, then report `failed` and ask the human.
