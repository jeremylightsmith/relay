defmodule Hamaca.Examples do
  @moduledoc """
  The public, read-only example boards — one per board template (RE444): **Streaks
  (bare-minimum)**, **Pantry (design-led)** and **Tiny Dungeon (three-brain)**.

  Their content is **loaded** at compile time from `docs/designs/templates/examples/<slug>.json`,
  one file per `Hamaca.Boards.templates/0` entry: the board name and key, the pitch, baton and
  facts lines, the WIP How/Why/Here text, per-stage notes (`note_kinds/0`), per-flow blurb +
  default-selected node, and the cards (listed top to bottom as they render). Every file is
  validated against its template — stages, sub-lanes, statuses, WIP limits, flow and node keys —
  and a bad file fails the build with an `ArgumentError` starting `"invalid example board: "`.
  `@external_resource` makes an edited file recompile this module.

  `seed!/2` creates the boards through `Hamaca.Boards` and `Hamaca.Cards` (their only write
  paths), one transaction per board, and is idempotent. It lives in its own boundary rather than
  under `Hamaca.Boards` because `Hamaca.Cards` already depends on `Hamaca.Boards`. The template's
  flows stay **disabled**, so no runner ever pulls a sample card.
  """

  use Boundary, deps: [Hamaca.Boards, Hamaca.Cards, Hamaca.Repo, Schemas]

  import Ecto.Query

  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Repo
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Stage
  alias Schemas.User

  @note_kinds [:full, :why]
  @batons [:ai, :human]

  @type note_kind :: :full | :why
  @type baton :: :ai | :human

  @type card :: %{
          ref_number: pos_integer(),
          title: String.t(),
          stage: String.t(),
          lane: :review | :done | nil,
          status: atom(),
          baton: baton(),
          tag: String.t() | nil,
          description: String.t(),
          tasks: [%{title: String.t(), done: boolean()}],
          question: String.t() | nil
        }

  @type example :: %{
          template: String.t(),
          name: String.t(),
          key: String.t(),
          pitch: String.t(),
          baton: %{ai: String.t(), human: String.t()},
          facts: String.t(),
          wip: %{how: String.t(), why: String.t(), here: String.t()},
          notes: %{String.t() => %{kind: note_kind(), text: String.t()}},
          flows: %{String.t() => %{blurb: String.t() | nil, selected: String.t()}},
          cards: [card()]
        }

  @examples_dir Path.expand("../../docs/designs/templates/examples", __DIR__)
  @templates Boards.templates()

  for %{slug: slug} <- @templates do
    @external_resource Path.join(@examples_dir, "#{slug}.json")
  end

  # Compile-time only: a JSON string → one of `allowed`'s atoms, never `String.to_atom/1`.
  to_enum! = fn value, allowed, what ->
    Enum.find(allowed, &(Atom.to_string(&1) == value)) ||
      raise ArgumentError, "invalid example board: #{what} #{inspect(value)} is not one of #{inspect(allowed)}"
  end

  invalid! = fn slug, message -> raise ArgumentError, "invalid example board: #{slug}: #{message}" end

  load_card = fn raw, template, slug ->
    stage = Enum.find(template.stages, &(&1.name == raw["stage"]))
    stage || invalid!.(slug, "card #{raw["ref"]}'s stage #{inspect(raw["stage"])} isn't one of the template's stages")

    lane = raw["lane"] && to_enum!.(raw["lane"], Stage.sublane_types(), "lane")

    if lane && lane not in stage.sublanes do
      invalid!.(slug, "card #{raw["ref"]}'s lane #{inspect(raw["lane"])} isn't a sub-lane of #{stage.name}")
    end

    status = to_enum!.(raw["status"], Card.statuses(), "status")

    if !Stage.valid_status?(status, lane || stage.type) do
      invalid!.(slug, "card #{raw["ref"]}'s status #{status} isn't valid in #{stage.name}")
    end

    if status == :needs_input != is_binary(raw["question"]) do
      invalid!.(slug, "card #{raw["ref"]} must carry a question exactly when it is needs_input")
    end

    %{
      ref_number: raw["ref"],
      title: raw["title"],
      stage: stage.name,
      lane: lane,
      status: status,
      baton: to_enum!.(raw["baton"], @batons, "baton"),
      tag: raw["tag"],
      description: raw["description"],
      tasks: Enum.map(raw["tasks"], &%{title: &1["title"], done: &1["done"] == true}),
      question: raw["question"]
    }
  end

  load_notes = fn raw, template, cards, slug ->
    Map.new(raw, fn {name, note} ->
      stage = Enum.find(template.stages, &(&1.name == name))
      stage || invalid!.(slug, "note #{inspect(name)} isn't one of the template's stages")
      kind = to_enum!.(note["kind"], @note_kinds, "note kind")
      held = Enum.count(cards, &(&1.stage == name))

      if kind == :full and held != stage.wip_limit do
        invalid!.(
          slug,
          "#{name} is noted full but holds #{held} cards against a WIP limit of #{inspect(stage.wip_limit)}"
        )
      end

      {name, %{kind: kind, text: note["text"]}}
    end)
  end

  load_flows = fn raw, template, slug ->
    flows = Map.new(template.flows, &{&1.key, &1})

    Map.new(raw, fn {key, flow} ->
      %{nodes: nodes} = Map.get(flows, key) || invalid!.(slug, "flow #{inspect(key)} isn't one of the template's flows")

      if !Enum.any?(nodes, &(&1.key == flow["selected"])) do
        invalid!.(slug, "flow #{key}'s selected node #{inspect(flow["selected"])} isn't one of its nodes")
      end

      {key, %{blurb: flow["blurb"], selected: flow["selected"]}}
    end)
  end

  @all Enum.map(@templates, fn template ->
         slug = template.slug
         doc = @examples_dir |> Path.join("#{slug}.json") |> File.read!() |> Jason.decode!()

         if doc["template"] != slug do
           invalid!.(slug, "the file's \"template\" #{inspect(doc["template"])} must match its file name")
         end

         cards = Enum.map(doc["cards"], &load_card.(&1, template, slug))

         case cards |> Enum.frequencies_by(& &1.ref_number) |> Enum.filter(fn {_ref, n} -> n > 1 end) do
           [] -> :ok
           dupes -> invalid!.(slug, "refs #{inspect(Enum.map(dupes, &elem(&1, 0)))} are used more than once")
         end

         %{
           template: slug,
           name: doc["name"],
           key: doc["key"],
           pitch: doc["pitch"],
           baton: %{ai: doc["baton"]["ai"], human: doc["baton"]["human"]},
           facts: doc["facts"],
           wip: %{how: doc["wip"]["how"], why: doc["wip"]["why"], here: doc["wip"]["here"]},
           notes: load_notes.(doc["notes"], template, cards, slug),
           flows: load_flows.(doc["flows"], template, slug),
           cards: cards
         }
       end)

  @doc "The kinds of per-stage note an example carries — the ONE list."
  @spec note_kinds() :: [note_kind()]
  def note_kinds, do: @note_kinds

  @doc "The two sides of the baton an example describes — the ONE list."
  @spec batons() :: [baton()]
  def batons, do: @batons

  @doc "Every example, in `Hamaca.Boards.templates/0` order."
  @spec all() :: [example()]
  def all, do: @all

  @doc "The example for template `slug`, or nil."
  @spec get(String.t()) :: example() | nil
  def get(slug), do: Enum.find(@all, &(&1.template == slug))

  @doc """
  Creates each missing example board for `owner`, in `all/0` order, and returns the template
  slugs it `created` and `skipped`. A board that already exists is skipped untouched, unless
  `reset: true`, which deletes and recreates it.

  Each board is built in ONE transaction: the board from its template (flows stay disabled),
  `Hamaca.Boards.mark_example/2`, then the cards through `Hamaca.Cards`, each with its mockup ref
  number. The transaction also keeps `request_input/3` from pushing "needs you" notifications
  to the owner's phone (pushes only dispatch outside a transaction).
  """
  @spec seed!(User.t(), keyword()) :: %{created: [String.t()], skipped: [String.t()]}
  def seed!(%User{} = owner, opts \\ []) do
    reset? = Keyword.get(opts, :reset, false)

    outcomes = Enum.map(@all, &seed_one(owner, &1, reset?))

    %{
      created: for({:created, slug} <- outcomes, do: slug),
      skipped: for({:skipped, slug} <- outcomes, do: slug)
    }
  end

  defp seed_one(owner, %{template: slug} = example, reset?) do
    case Boards.get_example_board(slug) do
      {:ok, _board} when not reset? ->
        {:skipped, slug}

      _missing_or_reset ->
        {:ok, _board} = Repo.transaction(fn -> create_example!(owner, example) end)
        {:created, slug}
    end
  end

  defp create_example!(owner, example) do
    Repo.delete_all(from b in Board, where: b.example_template == ^example.template)

    {:ok, board} = Boards.create_board(owner, %{name: example.name, key: example.key, template: example.template})
    {:ok, board} = Boards.mark_example(board, example.template)

    stages = Map.new(board.stages, &{stage_slot(board.stages, &1), &1})

    # `create_card/3` puts each new card on top of its stage, so create each stage's cards
    # bottom-up to leave the first-listed card on top.
    example.cards
    |> Enum.group_by(&{&1.stage, &1.lane})
    |> Enum.each(fn {_lane, cards} ->
      cards |> Enum.reverse() |> Enum.each(&create_card!(board, stages, owner, &1))
    end)

    max_ref = example.cards |> Enum.map(& &1.ref_number) |> Enum.max()
    set_card_seq!(board, max_ref)
    board
  end

  # Where a stage sits, in the content's terms: `{main stage name, nil}` for a main stage,
  # `{parent's name, sub-lane type}` for a sub-lane.
  defp stage_slot(_stages, %Stage{parent_id: nil, name: name}), do: {name, nil}

  defp stage_slot(stages, %Stage{parent_id: parent_id, type: lane}),
    do: {Enum.find(stages, &(&1.id == parent_id)).name, lane}

  defp create_card!(board, stages, owner, card) do
    stage = Map.fetch!(stages, {card.stage, card.lane})
    user = {:user, owner.id}

    set_card_seq!(board, card.ref_number - 1)
    {:ok, created} = Cards.create_card(stage, %{title: card.title, tag: card.tag, description: card.description}, user)

    {:ok, created} =
      case card.baton do
        :ai -> Cards.set_owners(created, [:agent], :agent)
        :human -> Cards.set_owners(created, [user], user)
      end

    {:ok, _card} = apply_status(created, card, user)
    add_tasks!(created, card.tasks)
  end

  defp apply_status(created, %{status: :needs_input, question: question}, _user),
    do: Cards.request_input(created, question, :agent)

  defp apply_status(%Card{status: status} = created, %{status: status}, _user), do: {:ok, created}

  defp apply_status(created, %{status: status, baton: baton}, user),
    do: Cards.set_status(created, %{status: status}, if(baton == :ai, do: :agent, else: user))

  defp add_tasks!(_card, []), do: :ok

  defp add_tasks!(card, tasks) do
    {:ok, inserted} = Cards.add_tasks(card, Enum.map(tasks, &%{title: &1.title}))

    for {%{done: true}, row} <- Enum.zip(tasks, inserted) do
      {:ok, _card} = Cards.set_sub_task_done(card, row.id, true)
    end

    :ok
  end

  defp set_card_seq!(%Board{id: id}, seq) do
    {1, _} = Repo.update_all(from(b in Board, where: b.id == ^id), set: [card_seq: seq])
  end
end
