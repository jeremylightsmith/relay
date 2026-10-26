defmodule HamacaWeb.DocsHTML do
  @moduledoc """
  Templates for the public docs pages (see the `docs_html` directory). Pages under
  `docs_html/pages/` are HEEx rather than markdown because they draw the board's own components
  (`board_card/1`, `status_badge/1`, `stage_type_icon/1`, `category_dot/1`, `flow_chip/1`), so
  their pictures can't drift from the board.

  Each picture is keyed by a value of the closed set it explains — `Schemas.Card.statuses/0`,
  `Schemas.Stage.categories/0`, `Schemas.Stage.types/0` — and looked up with `Map.fetch!/2`, so a
  value added to one of those sets fails the docs tests until it is pictured here.
  """
  use HamacaWeb, :html

  embed_templates "docs_html/*"
  embed_templates "docs_html/pages/*"

  # The template the How Hamaca works board picture draws, and the example cards it seeds.
  @example_template "design-led"
  @example_cards %{
    "Backlog" => [%{ref: "RE12", title: "Dark mode for exports", status: :ready, stage_type: :queue}],
    "Next up" => [%{ref: "RE14", title: "Offline map tiles", status: :ready, run: {:queued, %{key: "design"}}}],
    "Design" => [%{ref: "RE15", title: "Recipe sharing", status: :needs_input, question: "Cards or a list view?"}],
    "Plan" => [%{ref: "RE16", title: "Export the board as CSV", status: :working, progress: 40, active_owner: :ai}],
    "Code" => [
      %{ref: "RE17", title: "Retry failed webhooks", status: :failed, health: :stopped, log_text: "precommit failed 3×"}
    ],
    "Review" => [%{ref: "RE18", title: "Faster search", status: :in_review}],
    "Done" => [%{ref: "RE11", title: "Sign in with Google", status: :ready, stage_type: :done, done: true}]
  }

  @category_meanings %{
    unstarted: {"Not begun. Ideas, and work queued up next.", "Backlog, Next up"},
    planning: {"Being specified or designed, not built yet. Agents usually write the spec here.", "Design, Plan"},
    in_progress: {"Being built, reviewed or shipped.", "Code, Review, Deploy"},
    complete: {"Finished. A card blocking another one stops blocking once it gets here.", "Done"}
  }

  @type_meanings %{
    queue: {"Next up", "Cards wait here. A flow in the next stage pulls them from here."},
    planning: {"Plan", "Working out what to build. It can have a Review and a Done substage."},
    work: {"Code", "Building or shipping it."},
    review: {"Review", "A person clicks Approve or Request changes. A Review substage works the same way."},
    done:
      {"Done",
       "Finished. A Done substage partway along the board means parked: the card waits there for the next stage to pull it."}
  }

  @status_examples %{
    ready:
      {%{title: "Dark mode for exports", status: :ready, stage_type: :queue},
       "Nobody is working it. It stays where it is until someone moves it or a flow pulls it."},
    queued:
      {%{title: "Offline map tiles", status: :ready, run: {:queued, %{key: "design"}}},
       "A flow wants it, but no runner has room yet. It starts when one does."},
    working:
      {%{title: "Export the board as CSV", status: :working, progress: 40, active_owner: :ai},
       "An agent (or a person) is on it. Open the card to watch live."},
    needs_input:
      {%{title: "Recipe sharing", status: :needs_input, question: "Cards or a list view?"},
       "The agent asked a question it can't answer. Answer on the card and it carries on."},
    in_review:
      {%{title: "Faster search", status: :in_review}, "Waiting at a review stage for you to Approve or Request changes."},
    failed:
      {%{title: "Retry failed webhooks", status: :failed, health: :stopped, log_text: "precommit failed 3×"},
       "A run gave up. The card says why. Fix it, then retry or move it on."}
  }

  @doc "The example board's main stages, grouped by category in board order, each with its example cards."
  def example_board do
    template = Enum.find(Hamaca.Boards.templates(), &(&1.slug == @example_template))
    flow_stages = MapSet.new(template.flows, & &1.trigger.stage)

    stages =
      for stage <- template.stages do
        Map.merge(stage, %{
          flow?: MapSet.member?(flow_stages, stage.name),
          cards: Map.get(@example_cards, stage.name, [])
        })
      end

    for category <- Schemas.Stage.categories(),
        in_category = Enum.filter(stages, &(&1.category == category)),
        in_category != [],
        do: {category, in_category}
  end

  @doc "What a stage category means, and the example board's stages in it."
  def category_meaning(category), do: Map.fetch!(@category_meanings, category)

  @doc "An example stage name for a stage type, and what the type means."
  def type_meaning(type), do: Map.fetch!(@type_meanings, type)

  @doc "The board_card attributes that picture a card status, and what the status means."
  def status_example(status), do: Map.fetch!(@status_examples, status)

  @doc "The band label the board shows for a category."
  def category_label(category), do: category |> Atom.to_string() |> String.replace("_", " ")
end
