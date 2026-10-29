defmodule Hamaca.Repo.Migrations.SeedTasksFromMonolithicPlans do
  use Ecto.Migration

  # RE487 — a `foreach` flow's work list now comes only from a card's tasks (`sub_tasks` rows).
  # Before that, a card with no tasks fell back to parsing its plan's `## Task N:` headings at
  # run start. This seeds those headings as task rows for every live card that still relies on
  # the fallback, so deleting the fallback strands no card.
  #
  # The heading regex is a FROZEN copy of the retired plan parser — the sanctioned exception to
  # the magic-value rule (a migration never calls app code that may change later). Two to four
  # hashes (a single `#` is the plan's own title); a colon, em-dash, en-dash or hyphen after the
  # number; the `u` flag so the multibyte dashes match as characters.
  @heading ~r/^\#{2,4}[ \t]+Task[ \t]+\d+[ \t]*[-:—–][ \t]*(?<title>\S.*?)[ \t]*$/mu

  def up, do: seed!(repo())

  # Seeded rows are indistinguishable from authored ones, so there is nothing safe to undo.
  def down, do: :ok

  @doc "The data seed `up` runs — also exactly what its test executes. Idempotent."
  @spec seed!(module()) :: :ok
  def seed!(repo) do
    %{rows: rows} =
      repo.query!("""
      SELECT id, plan FROM cards
      WHERE archived_at IS NULL AND plan IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM sub_tasks WHERE sub_tasks.card_id = cards.id)
      ORDER BY id
      """)

    for [card_id, plan] <- rows,
        {title, position} <- plan |> parse() |> Enum.with_index() do
      repo.query!(
        """
        INSERT INTO sub_tasks (card_id, title, done, position, inserted_at, updated_at)
        VALUES ($1, $2, false, $3, NOW(), NOW())
        """,
        [card_id, title, position]
      )
    end

    :ok
  end

  @doc "A plan's `## Task N: <title>` heading titles, in document order."
  @spec parse(String.t() | nil) :: [String.t()]
  def parse(nil), do: []

  def parse(plan) when is_binary(plan),
    do: @heading |> Regex.scan(plan, capture: :all_names) |> List.flatten()
end
