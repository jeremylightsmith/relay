# CLI (`./hamaca`)

Your agents use `./hamaca` to read and update the board. You'll use it for three things:
`./hamaca start` to run agents on this machine, `./hamaca why RLY-12` when a card isn't moving,
and `./hamaca update` to refresh it.

It reads your board key from `HAMACA_API_KEY`. The board's address is built in, so set
`HAMACA_URL` only to point it at a different board. Anything it changes shows on the board as
Hamaca AI. Every command takes `--json`, and `./hamaca <command> -h` lists its options.

## Runner

| Command | What it does |
| --- | --- |
| `./hamaca start` | Run agents on this machine. It claims work from the board until you stop it. `--once` runs one job; `--dry-run` says what it would claim |
| `./hamaca runners` | Who's connected, how many jobs each can take, and what each is running |
| `./hamaca git-fetch` | `git fetch` with retries, for shell steps in a flow |

## Cards

**Look things up**

| Command | What it does |
| --- | --- |
| `./hamaca board` | Every stage and its cards |
| `./hamaca card RLY-12` | One card: description, plan, branch, timeline |
| `./hamaca search "login bug"` | Find cards by ref or by words in the title. Done cards are included; `--archived` adds archived ones |
| `./hamaca images RLY-12 --pull` | Download the images in a card's comments and review notes |

**Create and move**

| Command | What it does |
| --- | --- |
| `./hamaca create "Fix login"` | Create a card. `--stage Backlog` puts it in a stage; also takes `--description`, `--tag` and `--depends-on RLY-3,RLY-4` |
| `./hamaca move RLY-12 Code` | Move a card to a stage |
| `./hamaca title RLY-12 "…"` | Rename a card |
| `./hamaca tag RLY-12 bug` | Set a card's tag. Leave the tag off to clear it |
| `./hamaca status RLY-12 working` | Set a card's [status](/docs/statuses-and-outcomes) |
| `./hamaca depends RLY-12 RLY-3` | Make a card wait for others. See [Depending on another card](#depending-on-another-card) |
| `./hamaca archive RLY-12` | Take a card off the board. If a run is going, `./hamaca cancel` it first |
| `./hamaca unarchive RLY-12` | Put an archived card back |

**Write the work**

| Command | What it does |
| --- | --- |
| `./hamaca describe RLY-12 @ask.md` | Set the description: the ask, as stated |
| `./hamaca spec RLY-12 @spec.md` | Set the spec: what will be built |
| `./hamaca criteria RLY-12 @criteria.md` | Set the acceptance criteria a reviewer checks |
| `./hamaca plan RLY-12 @plan.md` | Set the plan's header. Tasks are added separately |
| `./hamaca tasks add RLY-12` | Add tasks to the end of the plan: `--task "Title" @body.md`, repeated for more |
| `./hamaca tasks list RLY-12` | The plan's tasks, with their ids |
| `./hamaca task show RLY-12 42` | One task, with its body |
| `./hamaca task update RLY-12 42` | Change a task's `--title` or `--body`. `./hamaca task rm RLY-12 42` removes it |
| `./hamaca check RLY-12 42` | Tick a task off |
| `./hamaca uncheck RLY-12 42` | Untick it |
| `./hamaca sub-tasks RLY-12 @tasks.md` | Replace the whole task list at once. Older; use `tasks add` |
| `./hamaca branch RLY-12 rly-12-…` | Record the card's git branch |
| `./hamaca pr RLY-12 <url>` | Record the card's pull request |
| `./hamaca comment RLY-12 "…"` | Comment on a card |
| `./hamaca attach RLY-12 shot.png` | Upload a file and print markdown that shows it |
| `./hamaca mockups RLY-12 a.html` | Attach HTML or image mockups, replacing the card's list. An HTML mockup must be one self-contained file; the only thing it can load is Google Fonts (`fonts.googleapis.com`, `fonts.gstatic.com`). `--pull` downloads them; `--clear` removes them |
| `./hamaca result RLY-12 @result.json` | Set the summary, changes and screenshots shown on the card. See [The card's result](#the-cards-result) |

**Hand the baton**

| Command | What it does |
| --- | --- |
| `./hamaca needs-input RLY-12 "…"` | Ask a person a question. The card waits for the answer |
| `./hamaca own RLY-12` | Take the card for the agent |
| `./hamaca release RLY-12` | Hand it back |
| `./hamaca approve RLY-12` | Approve a card at a review stage |
| `./hamaca reject RLY-12 "…"` | Request changes, with a note |

**Change the stages**

| Command | What it does |
| --- | --- |
| `./hamaca stages` | The board's stages in order, with their settings |
| `./hamaca stage add Triage` | Add a stage. `--after Spec` or `--before Spec` places it |
| `./hamaca stage set Code --wip 3` | Change a stage's name, type, WIP limit or description |
| `./hamaca stage move Code` | Move a stage, with `--before` or `--after` another |
| `./hamaca stage lane Code review on` | Turn a stage's Review or Done substage on or off |
| `./hamaca stage rm Triage` | Remove a stage. Refused (409, nothing written) while it holds cards or a flow uses it |

## Runs & flows

| Command | What it does |
| --- | --- |
| `./hamaca why RLY-12` | Why isn't this card moving? One plain answer |
| `./hamaca runs RLY-12` | The card's runs, step by step, with any failure in full |
| `./hamaca retry RLY-12` | Rerun a failed run from the step that failed. `--at STEP` picks another |
| `./hamaca cancel RLY-12` | Stop the card's run. The card stays where it is |
| `./hamaca advance RLY-12` | The current task is already done: tick it and go on to the next |
| `./hamaca outcome succeeded` | Report how a flow step went. Only flow steps call this |
| `./hamaca flow` | The board's flows. `./hamaca flow code` prints one |
| `./hamaca flow-push code code.json` | Replace a flow with an edited copy. See [Flows as data](#flows-as-data) |
| `./hamaca flow-stats code` | How long each step of a flow takes, what it costs, and how often it retries |
| `./hamaca audit` | Board health: problems in recent runs, and checks your CI runs that no flow does |

## Setup

| Command | What it does |
| --- | --- |
| `./hamaca update` | Refresh `./hamaca` and the files that come with it. `--check` shows what would change |
| `./hamaca setup status` | The board's setup checklist, and the step that's next |
| `./hamaca setup report 5.1` | Report a setup step, e.g. `--status done`. `/hamaca-onboard` does this for you |
| `./hamaca version` | Which build of Hamaca the board is running |

## Long text and single values

A text argument can come from a file with `@path`, or from stdin with `-`:

```bash
./hamaca spec RLY-12 @spec.md
git log -1 --format=%B | ./hamaca comment RLY-12 -
```

`--field` prints one value from the `--json` output, with no quotes:

```bash
./hamaca card RLY-12 --field status    # working
```

## The card's result

`./hamaca result` sets what the card shows when the work is done. It takes these three keys and
nothing else:

```json
{
  "summary": "Sign-in is one email field now.",
  "changes": ["Merges the two sign-in forms"],
  "screens": [{ "url": "/attachments/135e5539-…", "caption": "Sign in" }]
}
```

A screen's `url` is the screenshot itself. Upload it first, and use the path that prints:

```bash
./hamaca attach RLY-12 shot.png --field url    # /attachments/135e5539-…
```

## Depending on another card

Add a dependency when two cards would otherwise build the same thing twice. If card B uses
something card A creates, run `./hamaca depends B A`. If both need a thing that doesn't exist
yet, make one of them build it and point the other at it.

Two cards that only touch the same files don't need one. A card with dependencies won't start
until each one reaches Done.

## Keeping `./hamaca` current

`./hamaca start` updates itself. When the board has a newer version, it downloads it and
restarts between jobs, so nothing running is cut off.

`./hamaca update` refreshes everything Hamaca puts in your repo: `./hamaca`, `hamaca.md` and
the three `hamaca-*` skills, plus the old-name `./relay` shim and its three `relay-*` alias
skills. Those files belong to Hamaca, so an update overwrites any edits you made to them. It
also creates `.hamaca/runner.json` if you don't have one, but never overwrites it. In a repo
still set up under the old `./relay` names, it moves you over to the new ones.

```bash
./hamaca update --check    # what would change; writes nothing
./hamaca update
```

## Configuring the runner

The runner reads `.hamaca/runner.json`. The install creates it (or run
`./hamaca update --starter-only`), with a comment on every setting. It's yours to edit and
commit; updates never overwrite it.

| Setting | Default | What it does |
| --- | --- | --- |
| `auto_update` | `true` | `false` stops `./hamaca start` updating itself |
| `limits.max_five_hour` | no limit | Stop taking work at this share (0–1) of your Claude five-hour limit |
| `limits.max_seven_day` | no limit | The same for the seven-day limit |
| `worktrees.prepare` | `.hamaca/prepare-worktree.sh` | Runs in each card's new worktree, to install dependencies. If it fails, the run fails |
| `worktrees.cleanup` | `.hamaca/cleanup-worktree.sh` | Runs before a worktree is deleted, to stop anything it started |

When it reaches a usage limit, the runner finishes the jobs it has and takes no more. The board
shows it as RATE LIMITED until the limit resets.

## Flows as data

You edit flows in **Settings › Stages**. You can also pull one as JSON, edit it, and push it
back:

```bash
./hamaca flow code --json > code.json
./hamaca flow-push code code.json
```

If someone changed the flow since you pulled it, the push is refused; pull again and redo your
edit. A step that runs a command should check out the card's branch first (it's in
`vars.branch`) and commit at the end.

## Upgrading from ./relay

The CLI used to be called `./relay`. A repo set up then moves to the new names in two steps:

1. Run `./relay update`. It installs the new runner as `./relay`, so the repo keeps working
   under the old name.
2. Run `./relay update` again. This time the next `./relay update` renames the repo: `./relay`
   becomes `./hamaca` (a small `./relay` stays and runs it), `.relay/` becomes `.hamaca/`,
   `relay.md` becomes `hamaca.md`, the `relay-*` skills become `hamaca-*`, and the line in
   your `CLAUDE.md` or `AGENTS.md` points at `hamaca.md`. Commit the result.

Then stop the runner and start it again with `./hamaca start`.

Nothing breaks in between. `./relay`, the `RELAY_*` environment variables, `.relay/` and the
`relay-*` skills keep working until RE482 ends the compatibility window. Rename `RELAY_API_KEY`
in your shell setup to `HAMACA_API_KEY` when it suits you.
