# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It creates the user jeremy.lightsmith@gmail.com (if missing) and three boards
# owned by that user, each with its own plausible stage pipeline and a spread of
# cards across the stages:
#
#   * "Weekend Projects" — small, low WIP limits, only a handful of cards.
#   * "Product Team"     — a mid-size team board with a standard pipeline.
#   * "Acme Platform"    — a large board with generous WIP limits and lots of cards.
#
# Re-running is safe: each seed board is deleted (by slug, owner-scoped) and
# rebuilt, so counts never pile up. Only the three seed boards are touched.

import Ecto.Query

alias Ecto.Changeset
alias Relay.Repo
alias Schemas.Board
alias Schemas.Card
alias Schemas.CardOwner
alias Schemas.Stage
alias Schemas.SubTask
alias Schemas.User

now = DateTime.truncate(DateTime.utc_now(), :second)

# --- the human every seed board belongs to ---------------------------------
email = "jeremy.lightsmith@gmail.com"

user =
  case Repo.get_by(User, email: email) do
    nil ->
      %User{provider: "seed", provider_uid: "seed-" <> email}
      |> User.changeset(%{email: email, name: "Jeremy Lightsmith"})
      |> Repo.insert!()

    %User{} = existing ->
      existing
  end

# --- little builders --------------------------------------------------------
add_owner = fn card, owner ->
  case owner do
    :agent ->
      %CardOwner{card_id: card.id, actor_type: :agent} |> CardOwner.changeset() |> Repo.insert!()

    :user ->
      %CardOwner{card_id: card.id, actor_type: :user, user_id: user.id}
      |> CardOwner.changeset()
      |> Repo.insert!()

    nil ->
      :ok
  end
end

add_subs = fn card, subs ->
  subs
  |> Enum.with_index(1)
  |> Enum.each(fn {{title, done}, pos} ->
    %SubTask{card_id: card.id, position: pos}
    |> SubTask.changeset(%{title: title, done: done})
    |> Repo.insert!()
  end)
end

# --- big-document generators ------------------------------------------------
# Cards that have moved past the Spec + Plan stages carry the artifacts those
# stages produced. We synthesize realistic markdown padded to a target size so
# the app is exercised with the specs (~5–10 KB) and plans (~20–100 KB) a real
# board accumulates. `pad` appends sections until the byte target is hit (O(n),
# via an iolist), so this stays fast even for the 100 KB plans.
pad = fn seed, target, section_fun ->
  Enum.reduce_while(1..100_000, {[seed], byte_size(seed)}, fn i, {parts, size} ->
    if size >= target do
      {:halt, IO.iodata_to_binary(Enum.reverse(parts))}
    else
      section = section_fun.(i)
      {:cont, {[section | parts], size + byte_size(section)}}
    end
  end)
end

# Deterministic per-card sizes (no Math.random in seed scripts): specs land in
# 5–10 KB, plans in 20–100 KB. A Knuth multiplicative hash spreads the sizes
# across the full range even though ref_numbers are small (1..35).
spec_target = fn ref -> 5_000 + rem(ref * 2_246_822_519, 5_001) end
plan_target = fn ref -> 20_000 + rem(ref * 2_246_822_519, 80_001) end

make_spec = fn title, target ->
  intro = """
  # Spec: #{title}

  _Status: approved — carried forward from the Spec stage._

  ## Problem statement

  #{title} today forces users through a brittle, manual flow. This spec defines the
  desired behavior, the acceptance criteria, and the edge cases the implementation
  must satisfy before it can move on to Plan.

  ## Goals

  - Deliver #{title} with no regressions to existing flows.
  - Keep every state transition observable: it emits an activity entry.
  - Ship behind a flag so we can dark-launch and measure before rollout.

  ## Non-goals

  - Rewriting adjacent subsystems.
  - Changing the public API contract in this iteration.

  """

  section = fn i ->
    """
    ## Requirement #{i}

    R#{i}. The system SHALL handle #{title} such that user-facing behavior is
    predictable and reversible. When the actor performs the primary action, the
    resulting state MUST be persisted atomically and broadcast to every connected
    session. If the operation fails, the prior state MUST be restored and the actor
    notified with an actionable message.

    ### Acceptance criteria

    - Given valid input, when the action runs, then the outcome is recorded and visible within one render cycle.
    - Given invalid input, when the action runs, then a validation error is shown and nothing is persisted.
    - Given a concurrent edit, when two actors act, then writes converge and both sessions agree.

    ### Edge cases

    - Empty / whitespace-only input is rejected before it reaches the context.
    - Archived or deleted parents are treated as not-found, never as errors.
    - Permission boundaries are re-checked server-side, never trusted from the client.

    """
  end

  pad.(intro, target, section)
end

make_plan = fn title, target ->
  intro = """
  # Implementation plan: #{title}

  Derived from the approved spec. Each task below is independently testable and is
  checked off at the Code stage. Tasks are ordered; later tasks assume earlier ones.

  """

  section = fn i ->
    """
    ## Task #{i}: slice #{i} of #{title}

    **Intent.** Implement slice #{i} of #{title} using strict TDD — write the failing
    test first, then the minimal code to pass, then refactor.

    **Files touched**

    - `lib/relay/<context>.ex` — new/changed context function
    - `lib/relay_web/live/<view>.ex` — wire the event and re-stream the affected column
    - `test/relay/<context>_test.exs` — unit coverage
    - `test/relay_web/live/<view>_test.exs` — LiveView coverage

    **Sketch**

    ```elixir
    def action_#{i}(%Struct{} = struct, attrs, actor) do
      struct
      |> Struct.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, updated} -> broadcast({:updated, updated}); {:ok, updated}
        {:error, changeset} -> {:error, changeset}
      end
    end
    ```

    **Test plan**

    1. Happy path: valid attrs persist and broadcast exactly once.
    2. Validation: a blank required field returns `{:error, changeset}` and writes nothing.
    3. Authz: a non-owner actor is rejected server-side.
    4. Idempotency: replaying the same event does not double-apply.

    **Notes.** Keep the change behind the feature flag and do not touch the public API
    contract. Ensure `mix precommit` stays green — compile warnings-as-errors, format,
    credo --strict, sobelow, deps.audit, and the full suite.

    """
  end

  pad.(intro, target, section)
end

# Builds one board: deletes any prior seed board with the same slug, inserts the
# stages in order, then inserts each stage's cards (positions 1..n) with a
# board-sequential ref_number, bumping the board's card_seq to match.
build_board = fn %{name: name, slug: slug, key: key} = board_attrs, stage_specs, card_specs ->
  long_docs = Map.get(board_attrs, :long_docs, false)
  Repo.delete_all(from(b in Board, where: b.owner_id == ^user.id and b.slug == ^slug))

  board =
    %Board{owner_id: user.id}
    |> Board.changeset(%{name: name, slug: slug, key: key})
    |> Repo.insert!()

  stages =
    for {{sname, category, type, ai, wip}, pos} <- Enum.with_index(stage_specs, 1) do
      %Stage{board_id: board.id}
      |> Stage.changeset(%{
        name: sname,
        position: pos,
        category: category,
        type: type,
        ai_enabled: ai,
        wip_limit: wip
      })
      |> Repo.insert!()
    end

  last_ref =
    Enum.reduce(stages, 0, fn stage, ref_acc ->
      stage_cards = Enum.filter(card_specs, &(&1.stage == stage.name))

      stage_cards
      |> Enum.with_index(1)
      |> Enum.reduce(ref_acc, fn {card_spec, position}, ref ->
        ref = ref + 1
        status = Map.get(card_spec, :status, Stage.default_status(stage.type))

        # Cards past the Spec + Plan stages (in_progress / complete) carry the big
        # spec + plan those stages produced — but only on boards with a real
        # spec/plan pipeline (long_docs).
        past_planning? = long_docs and stage.category in [:in_progress, :complete]

        spec_text = if past_planning?, do: make_spec.(card_spec.title, spec_target.(ref))
        plan_text = if past_planning?, do: make_plan.(card_spec.title, plan_target.(ref))

        card =
          %Card{board_id: board.id, stage_id: stage.id, position: position, ref_number: ref}
          |> Card.changeset(%{
            title: card_spec.title,
            tag: Map.get(card_spec, :tag),
            description: Map.get(card_spec, :description),
            spec: spec_text,
            plan: plan_text
          })
          |> Changeset.put_change(:status, status)
          |> then(fn cs ->
            if status == :needs_input, do: Changeset.put_change(cs, :blocked_since, now), else: cs
          end)
          |> Repo.insert!()

        add_owner.(card, Map.get(card_spec, :owner))
        add_subs.(card, Map.get(card_spec, :subs, []))
        ref
      end)
    end)

  Repo.update!(Changeset.change(board, card_seq: last_ref))
  IO.puts("  #{name} — #{length(stages)} stages, #{last_ref} cards")
  board
end

# ---------------------------------------------------------------------------
# Board 1: Weekend Projects — small, low WIP, few cards.
# ---------------------------------------------------------------------------
weekend_stages = [
  {"Ideas", :unstarted, :queue, false, nil},
  {"Doing", :in_progress, :work, true, 2},
  {"Review", :in_progress, :review, false, 1},
  {"Done", :complete, :done, false, nil}
]

weekend_cards = [
  %{stage: "Ideas", title: "Repot the balcony herbs", tag: "home"},
  %{stage: "Ideas", title: "Sketch a logo for the side project", tag: "design"},
  %{stage: "Ideas", title: "Try the new sourdough recipe", tag: "kitchen"},
  %{
    stage: "Doing",
    title: "Add dark mode to the personal site",
    status: :working,
    owner: :agent,
    tag: "web",
    subs: [{"Add theme tokens", true}, {"Toggle in navbar", false}, {"Persist the choice", false}]
  },
  %{
    stage: "Doing",
    title: "Fix the broken RSS feed encoding",
    status: :needs_input,
    owner: :agent,
    tag: "bug",
    description: "The feed validator flags invalid UTF-8 in a few older posts — which do we keep?"
  },
  %{stage: "Review", title: "Rewrite the About page", status: :in_review, owner: :user, tag: "content"},
  %{stage: "Done", title: "Renew the domain name", owner: :user},
  %{stage: "Done", title: "Publish 'Elixir streams' post", owner: :user, tag: "content"}
]

# ---------------------------------------------------------------------------
# Board 2: Product Team — mid-size, standard pipeline.
# ---------------------------------------------------------------------------
product_stages = [
  {"Backlog", :unstarted, :queue, false, nil},
  {"Next up", :unstarted, :queue, false, 5},
  {"Spec", :planning, :planning, true, 3},
  {"Plan", :planning, :planning, true, 3},
  {"Build", :in_progress, :work, true, 4},
  {"Code review", :in_progress, :review, false, 3},
  {"Deploy", :in_progress, :work, true, 2},
  {"Shipped", :complete, :done, false, nil}
]

product_cards = [
  %{stage: "Backlog", title: "Bulk CSV export for reports", tag: "feature"},
  %{stage: "Backlog", title: "Dark mode for the dashboard", tag: "ui"},
  %{stage: "Backlog", title: "Deprecate the v1 webhooks", tag: "api"},
  %{stage: "Backlog", title: "Audit-log retention policy", tag: "infra"},
  %{stage: "Next up", title: "Password-reset email deliverability", tag: "bug"},
  %{stage: "Next up", title: "Add SSO via Google Workspace", tag: "auth"},
  %{stage: "Next up", title: "Rate-limit the public API", tag: "api"},
  %{
    stage: "Spec",
    title: "Team billing & seats",
    status: :working,
    owner: :agent,
    tag: "billing",
    subs: [{"Define the seat model", true}, {"Proration rules", false}]
  },
  %{
    stage: "Spec",
    title: "Realtime presence indicators",
    status: :needs_input,
    owner: :agent,
    tag: "feature",
    description: "Need product to confirm which surfaces should show presence."
  },
  %{stage: "Plan", title: "Notification preferences center", status: :working, owner: :agent, tag: "feature"},
  %{
    stage: "Build",
    title: "Inline comments on cards",
    status: :working,
    owner: :agent,
    tag: "feature",
    subs: [{"Schema + migration", true}, {"LiveView panel", true}, {"Broadcast updates", false}]
  },
  %{stage: "Build", title: "Fix the N+1 on the board query", status: :working, owner: :agent, tag: "perf"},
  %{stage: "Build", title: "Keyboard shortcuts for the board", status: :ready, owner: :user, tag: "ui"},
  %{stage: "Code review", title: "Refactor the auth pipeline", status: :in_review, owner: :user, tag: "auth"},
  %{stage: "Code review", title: "Add WIP-limit enforcement", status: :in_review, owner: :user, tag: "feature"},
  %{stage: "Deploy", title: "Roll out card archiving", status: :working, owner: :agent, tag: "release"},
  %{stage: "Shipped", title: "Board settings redesign", owner: :user},
  %{stage: "Shipped", title: "OAuth login", owner: :user},
  %{stage: "Shipped", title: "Activity feed v1", owner: :agent}
]

# ---------------------------------------------------------------------------
# Board 3: Acme Platform — large, high WIP, lots of cards.
# ---------------------------------------------------------------------------
acme_stages = [
  {"Inbox", :unstarted, :queue, false, nil},
  {"Triage", :unstarted, :queue, false, nil},
  {"Discovery", :planning, :planning, true, 6},
  {"Design", :planning, :planning, true, 6},
  {"In progress", :in_progress, :work, true, 12},
  {"Code review", :in_progress, :review, false, 8},
  {"QA", :in_progress, :work, true, 8},
  {"Staging", :in_progress, :work, true, 6},
  {"Released", :complete, :done, false, nil}
]

acme_cards = [
  %{stage: "Inbox", title: "Customer: export to Salesforce", tag: "request"},
  %{stage: "Inbox", title: "Investigate signup drop-off", tag: "growth"},
  %{stage: "Inbox", title: "Localize the app for de-DE", tag: "i18n"},
  %{stage: "Inbox", title: "SOC 2 evidence collection", tag: "compliance"},
  %{stage: "Inbox", title: "Mobile push notifications", tag: "mobile"},
  %{stage: "Triage", title: "500s on the billing page", tag: "bug"},
  %{stage: "Triage", title: "Slow search for large orgs", tag: "perf"},
  %{stage: "Triage", title: "GDPR data-export request flow", tag: "compliance"},
  %{stage: "Discovery", title: "Usage-based pricing model", status: :working, owner: :agent, tag: "billing"},
  %{
    stage: "Discovery",
    title: "Multi-region data residency",
    status: :needs_input,
    owner: :agent,
    tag: "infra",
    description: "Legal needs to confirm the EU residency requirements before we design storage."
  },
  %{stage: "Discovery", title: "AI summary of account health", status: :working, owner: :agent, tag: "ai"},
  %{
    stage: "Design",
    title: "New onboarding wizard",
    status: :working,
    owner: :agent,
    tag: "ux",
    subs: [{"Flow diagram", true}, {"Hi-fi mockups", false}]
  },
  %{stage: "Design", title: "Admin console IA refresh", status: :ready, owner: :user, tag: "ux"},
  %{stage: "Design", title: "Empty states across the app", status: :working, owner: :agent, tag: "ux"},
  %{stage: "Design", title: "Design tokens migration", status: :needs_input, owner: :agent, tag: "design"},
  %{stage: "In progress", title: "Break out the billing service", status: :working, owner: :agent, tag: "infra"},
  %{stage: "In progress", title: "Webhooks v2 delivery guarantees", status: :working, owner: :agent, tag: "api"},
  %{
    stage: "In progress",
    title: "Org-level RBAC",
    status: :working,
    owner: :agent,
    tag: "auth",
    subs: [{"Role schema", true}, {"Policy checks", true}, {"UI for roles", false}]
  },
  %{stage: "In progress", title: "Replace Sidekiq with Oban", status: :working, owner: :agent, tag: "infra"},
  %{stage: "In progress", title: "Bulk actions on the orders table", status: :working, owner: :agent, tag: "feature"},
  %{stage: "In progress", title: "Fix the flaky checkout tests", status: :ready, owner: :user, tag: "bug"},
  %{stage: "In progress", title: "Search relevance tuning", status: :working, owner: :agent, tag: "perf"},
  %{stage: "In progress", title: "Audit-log UI", status: :needs_input, owner: :agent, tag: "feature"},
  %{stage: "Code review", title: "Rate-limiter middleware", status: :in_review, owner: :user, tag: "api"},
  %{stage: "Code review", title: "Stripe webhook idempotency", status: :in_review, owner: :user, tag: "billing"},
  %{stage: "Code review", title: "Feature-flag service", status: :in_review, owner: :user, tag: "infra"},
  %{stage: "Code review", title: "CSV import validation", status: :in_review, owner: :user, tag: "feature"},
  %{stage: "QA", title: "Regression pass: checkout", status: :working, owner: :agent, tag: "qa"},
  %{stage: "QA", title: "Load-test the search API", status: :ready, owner: :user, tag: "perf"},
  %{stage: "QA", title: "Verify EU data residency", status: :working, owner: :agent, tag: "infra"},
  %{stage: "Staging", title: "Deploy RBAC to staging", status: :working, owner: :agent, tag: "release"},
  %{stage: "Staging", title: "Smoke-test webhooks v2", status: :working, owner: :agent, tag: "qa"},
  %{stage: "Released", title: "New pricing page", owner: :user},
  %{stage: "Released", title: "Two-factor auth", owner: :user},
  %{stage: "Released", title: "Realtime order updates", owner: :agent}
]

IO.puts("Seeding boards for #{email}:")

build_board.(
  %{name: "Weekend Projects", slug: "weekend-projects", key: "WKND", long_docs: false},
  weekend_stages,
  weekend_cards
)

build_board.(
  %{name: "Product Team", slug: "product-team", key: "PROD", long_docs: true},
  product_stages,
  product_cards
)

build_board.(
  %{name: "Acme Platform", slug: "acme-platform", key: "ACME", long_docs: true},
  acme_stages,
  acme_cards
)

IO.puts("Done.")
