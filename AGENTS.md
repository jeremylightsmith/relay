## What Relay is

Relay is an **AI-first kanban board**. The core idea is *passing the baton*: work moves
back and forth between humans and AI agents, and the board makes that hand-off explicit —
whose turn it is, what's blocked on a human, and what an agent is actively working. Treat
"who holds the baton" (human vs. agent) as a first-class property of a card, not an
afterthought. See [`docs/vision.md`](docs/vision.md) for the product north star.

**Terminology:** the board vocabulary — **stage / substage**, card, status, baton, the review
gate, and the "next stage or substage" Approve rule — is defined in
[`docs/glossary.md`](docs/glossary.md). Use those terms; it's the terminology source of truth.

**Design source of truth:** hi-fi mockups live in [`docs/designs/`](docs/designs/README.md)
(pulled from the Claude Design project). Build the LiveView UI to match them. The palette
encodes the core idea — **Human = blue** (`--color-primary`), **AI = violet**
(`--color-secondary`), Done = green, Blocked = amber — set these as the daisyUI theme in
`assets/css/app.css`. The Design System mockup maps each element to a daisyUI primitive.

[`docs/designs-as-is/`](docs/designs-as-is/README.md) is the **opposite direction and carries
no authority**: `.dc.html` snapshots generated *from* the running app by
`bin/design-capture.mjs` (see `/design-capture`), so the design project can iterate from what
shipped. Never treat one as a spec, never hand-edit one, and never write a capture into
`docs/designs/` — when a capture and the app disagree, the capture is stale.

**Client strategy (important for where code goes):** the LiveView web app is the single
source of truth for UI and real-time logic. Mobile ships as a **thin native wrapper** around
that same LiveView UI — so **build features in LiveView, not in a parallel client**. We do
*not* maintain a separate mobile UI or API today. LiveView Native is a documented future
upgrade path, adopted for iOS and Android together once the Android client is stable. Full
rationale in [ADR 0001](docs/adr/0001-client-architecture.md) — read it before adding any
client-side or API surface.

**Working Relay from Claude Code:** the `mix relay` CLI + REST API let a Claude session pull a
card, work it, and hand it back. See [`relay.md`](relay.md).

## Skill discipline

This project ships skills in `.claude/skills/` and a pipeline
(`/brainstorm` → `/write-plan` → the Code flow → `/finish`). They only help if you actually
use them.

- **If there's even a reasonable chance a skill applies, invoke it (via the `Skill` tool)
  BEFORE acting** — before exploring, before clarifying questions, before writing code. An
  invoked skill that turns out not to fit costs nothing; skipping one that fit costs rework.
- **Process skills fire first, then implementation.** "Let's build X" → `brainstorm` first.
  "Fix this bug / a test fails" → `systematic-debugging` first. Implementing a feature → the
  `test-driven-development` skill before any code. About to claim something works/passes →
  `verification-before-completion`.
- **Editing the factory triggers `/relay-doctor`.** After you change a flow (or push one with
  `./bin/relay flow-push`), or add, rename, or remove a `.claude/agents/*.md`,
  `.claude/skills/*/SKILL.md`, or `.claude/commands/*.md`, run `/relay-doctor` by hand in an
  interactive session — it asks questions, so never invoke it from a flow node. It checks
  that every flow node still resolves to a real step in this repo and walks you through each
  fix. A flow that names an agent this repo no longer has fails at run time, not at edit time.
- **Wiring a repo to a board is `/relay-onboard`.** When a repo has no working flow yet — no
  `.claude/` factory, or a factory and a flow that disagree wholesale — run `/relay-onboard`
  interactively: it picks a path (seed / adopt / hybrid) with you and loops on `/relay-doctor`
  until zero errors, then offers to enable the flows. `/relay-doctor` is the narrower tool —
  reach for it when the repo is already wired and one node broke.
- **These thoughts are rationalizations — stop and check for a skill instead:** "this is too
  simple," "let me just explore first," "I'll check the files quickly," "the skill is
  overkill," "I already know what that means," "I'll do this one thing first."
- **You're still in control:** explicit instructions here or from the user always outrank a
  skill. A skill never overrides `mix precommit` passing or the rules below.

## Project guidelines

- Running `mix precommit` is REQUIRED on every development cycle and must pass before work is considered done. It runs compile (warnings as errors), `mix format` (with Styler), `mix credo --strict`, `mix sobelow`, `mix deps.audit`, and the full test suite (warnings as errors). Fix any failure before finishing — never commit work with a failing `mix precommit`.
- **`bin/relay` carries `EXECUTOR_VERSION` — bump it on every change to that file.** A running
  `relay execute` holds the version it started with in memory, so an unbumped fix reaches
  nobody: the server compares the executor's declared version against
  `Relay.Runs.min_executor_version/0` and **refuses work** to anything below it (409
  `executor_outdated`), which is the only thing that turns "the fix was merged" into "the fix
  is running". `bin/test_relay.py`'s `ExecutorFingerprintGuardTest` enforces this — it hashes
  `bin/relay` with the two constant lines masked and fails with the exact fingerprint to paste
  into `EXECUTOR_FINGERPRINT`. Raise `@min_executor_version` in `lib/relay/runs.ex` only when
  running the old executor is genuinely worse than a stopped one.
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps
- **The current-state architecture lives in [`docs/architecture/`](docs/architecture/README.md)** and staying current is a gate: if your branch adds or changes a **context, PubSub topic, API endpoint, or supervised process**, update the matching `docs/architecture/` page in the same branch. The whole-branch final review treats a stale page as a blocking finding.
- **Architecture decisions live in [`docs/adr/`](docs/adr/README.md)** — read the index before changing cross-cutting structure. Notably [ADR 0001](docs/adr/0001-client-architecture.md) fixes the LiveView-first + thin-native-wrapper client strategy: keep UI and real-time logic in LiveView; do not stand up a parallel mobile client or API.
- **Context boundaries are enforced by [`boundary`](https://hexdocs.pm/boundary)** (wired into the compiler). The web layer (`RelayWeb`) may only call the domain through `Relay`'s exported contexts; contexts may not reach into the web layer. Each context is its own sub-boundary declared in `lib/relay.ex` — when you add a context, give it `use Boundary` and add it to `Relay`'s `exports`. A boundary violation fails compilation.
- **A magic value is defined exactly once.** Closed sets (statuses, outcomes, job states, node
  kinds, isolation classes) and policy numbers (thresholds, caps, grace windows) live as ONE
  named function/attribute on the module that owns the concept — the schema for a vocabulary
  (e.g. `Schemas.Run.active_statuses/0`), the domain module for a policy — and every consumer
  calls it. Never re-type a list literal (`in [:running, :parked]`) or partition (active vs
  terminal) in a second module, the web layer, or a test when a source function exists; if none
  exists, add it where the concept lives and call it from both places. Anything mirrored across
  the wire into `bin/relay` must be pinned by the executor contract fixture
  (`test/fixtures/executor_contract.json`, RLY-176) so drift breaks CI instead of shipping.
  Nearly every recent engine bug reduced to "two copies of one fact disagreed" — reviews should
  treat a duplicated closed set the way they treat a failing test.
- **No color literals in the web layer or in the app stylesheets.** `oklch(...)`, hex, `rgb()`
  and the raw Tailwind palette classes (`text-white`, `bg-slate-200`, …) do not flip with
  `data-theme`, so a screen built by transcribing a light-only artboard breaks dark mode. The
  only place a raw color may appear *unannounced* is inside the two
  `@plugin "../vendor/daisyui-theme"` blocks in `assets/css/app.css` and
  `assets/css/storybook.css`, which is where the tokens are defined.
  Everywhere else use the daisyUI semantic tokens — `bg-base-100`, `text-base-content/60`,
  `border-base-300`, `var(--color-primary)`, `color-mix(in oklab, var(--color-warning) 15%,
  var(--color-base-100))` — and prefer a shared control over a repeated inline style. The
  literal → token mapping is documented at the top of the theming section of `app.css` and
  enforced by `test/relay_web/theme_tokens_test.exs` (RE237). A **genuine** exception — a color
  no brand role can express, such as a per-entity hash-derived hue or a third-party brand mark —
  is opted out explicitly: put a trailing `# theme-tokens:allow: <reason>` comment on the one
  offending line (the usual case; it exempts that line only), or add an `@allowlist` entry in
  that test when the literal is unique to its file and the line carries no comment (`.heex`,
  which has no `#` comment syntax). Both are inventoried by the same test, so a new exception is
  a deliberate, reviewable test edit — not something you can slip in unnoticed.

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- **Never** use `@apply` when writing raw css
- **daisyUI is adopted for this app** (it is already a dependency). Prefer daisyUI components (`btn`, `card`, `badge`, `select`, `input`, `modal`, `join`, …) and theme them via the `light` / `dark` daisyUI theme tokens defined in `app.css` (mirror any theme/plugin change into `assets/css/storybook.css`). Reach for hand-written Tailwind only when daisyUI has no fitting primitive.
- **Storybook is the home for every reusable component.** Whenever you abstract a reusable component, add or refresh its story under `storybook/` and **tell the user, including a link to that component's storybook page** (e.g. `/storybook/core_components/section_label`).
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

## Phoenix / Elixir stack guidance

Framework-level rules for Elixir, Phoenix, Ecto, HEEx, and LiveView live in
[`docs/phoenix-usage-rules.md`](docs/phoenix-usage-rules.md). They load automatically
when you work under `lib/` or `test/` (via `lib/CLAUDE.md` and `test/CLAUDE.md`), so
they stay out of context on planning, docs, and board sessions. Read that file
directly before writing Elixir or HEEx if it is not already loaded.
