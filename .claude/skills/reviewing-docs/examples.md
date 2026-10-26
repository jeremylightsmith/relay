# Calibration examples for reviewing-docs

Excerpts were fetched 2026-10-26. Quote them as patterns, not as text to copy.

## Good: what "reads human" looks like

**Django tutorial, part 1** — promise, then a concrete thing you'll build, in user terms:
> "Let's learn by example. Throughout this tutorial, we'll walk you through the creation of a
> basic poll application. It'll consist of two parts: A public site that lets people view polls
> and vote in them. An admin site that lets you add, change, and delete polls."

It says nothing about models or ORM yet. Those come once you need them.

**Fly.io, Fly Launch**: answers the reader's worry before they raise it:
> "`fly launch` scans your project and, for most common languages and frameworks, generates a
> Dockerfile and configuration for you. You don't need to write a Dockerfile first. If your
> project already has one, Fly Launch can use it instead."

**Rust Book, Hello World**: meets the reader where they are, sets a small goal that can't fail, and states the one prerequisite:
> "Now that you've installed Rust, it's time to write your first Rust program. … Note: This
> book assumes basic familiarity with the command line."

**Stripe Checkout quickstart**: headings are verbs ("Create a Checkout Session"). It gives you test data so you can check the result yourself, then tells you when you've succeeded:
> "Use any of these test cards to simulate a payment." … "Congratulations! You have a basic
> Checkout integration working."

**Tailwind, utility classes**: one sentence of "you" with the jargon explained in brackets, an example straight away, and the reader's objection named:
> "You style things with Tailwind by combining many single-purpose presentational classes
> (utility classes) directly in your markup … Styling things this way contradicts a lot of
> traditional best practices, but once you try it you'll quickly notice some really important
> benefits"

**Plausible**: anchors to something you already know, then lists benefits the reader cares about. It uses no internal terms:
> "Plausible Analytics is a simple, privacy-friendly alternative to Google Analytics. No
> cookies, no personal data collection, no consent banners required."

## Bad → rewrite pairs

| Smell | Before | After |
|---|---|---|
| Meta-opener | "This page is written so an agent can follow it." | Cut. Agents read `relay.md`. |
| Describes the system, not the reader | "Relay provides a robust AI-first kanban experience that serves as a testament to human–agent collaboration." | "Put a card on the board and an agent starts on it. When it needs you, the card turns blue." |
| Implementation leak | "it fetches `./relay` from `$RELAY_URL/api/scaffold/relay` with your board's URL already baked in" | "It downloads `./relay`, already set up for your board." |
| Card sediment | "(an exported `RELAY_URL` still overrides it, and `./relay update` keeps it)" | Move to the CLI reference. A newcomer never needs this. |
| Hedge and parenthetical stack | "The runner will (generally) pick up cards (unless paused), which may (in some cases) require a restart." | "The runner picks up new cards on its own. If you paused it, run `./relay start`." |
| Passive voice hides who acts | "The card is moved to Review once the plan has been completed." | "When the agent finishes, it moves the card to Review for you to approve." |
| Undefined internal terms | "seeds the Spec:Review, Spec:Done and Plan:Done lanes" | Cut, or: "Each stage has a lane where finished cards wait for your OK." |
| Ticket or ADR refs | "As of RE425, runner versions are enforced (see RLY-176)." | "If Relay says your runner is out of date, run `./relay update` and restart it." |
| Em-dash chain | "Cards move between stages — each with its own flow — and agents — when allowed — work them." | "Each stage has its own flow. Where you allow it, an agent works the card." |
| Bold on everything | "**That is the whole of setup.** … **no access to the Relay repository is needed** … **Step 4 of the wizard gives you the install command**" | At most one bold phrase per section, for the thing that hurts if you miss it ("The key is shown once. Copy it now."). |
| Flat list, no priority | Every config key in the main path: `base`, `limits.max_five_hour`, capacity classes… | "Most people don't change anything here. Other options are in the runner reference." |
| No example | "Questions can be posed to humans via the needs-input mechanism." | "A stuck agent asks you directly, for example 'Include archived cards in the export?' You answer on the card." |
| AI rhetoric | "Relay isn't just a board. It's a fast, flexible, and powerful workspace." | "Relay is a kanban board where agents do some of the cards." |

## Anchor: a page that scores low

**Read this only after you've scored your own page.** If the page under review *is* this one, score it blind first, then compare.

`priv/docs/getting-started.md` as of 2026-10-26 scored **5/20 (rewrite)**. An unprimed reviewer gave it 6/10. Use this to check you aren't marking too generously.

| # | Score | Evidence |
|---|---|---|
| 1 | 1 | "From nothing to a card being worked by agents" is close to an outcome, but the next line is "This page is written so an **agent** can follow it." |
| 2 | 0 | It's a tutorial, but step 3 carries an ownership table and update mechanics. Step 4 carries usage-limit config. |
| 3 | 0 | `base`, `limits` and the capacity classes all sit in the main path with no "you can skip this". |
| 4 | 1 | 229 words before the first command, and that command only exports variables. |
| 5 | 0 | Spec:Review lanes, FLOW band, `shared_clean`/`exclusive` and "sub-steps 5.1–5.8" are all undefined. |
| 6 | 0 | `/api/scaffold/relay`, `--starter-only`, and "scaffold manifest" all appear. |
| 7 | 1 | It uses "you", but reads like a spec ("Relay owns exactly five files in your project and updates them as a set"). |
| 8 | 0 | Step 3's second paragraph puts six facts in two sentences. |
| 9 | 0 | 3.2 bold spans per 100 words. |
| 10 | 2 | Good. "Your machine should appear with a FRESH pill", plus the "When a card does not move" checklist. |

The page's best section is the troubleshooting list, which is ordered, concrete and tells you what you should see. That's the voice to keep.
