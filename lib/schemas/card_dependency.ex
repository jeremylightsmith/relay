defmodule Schemas.CardDependency do
  @moduledoc """
  One dependency edge between two cards on the same board (RE93): `card_id` is the **dependent**
  (blocked) card, `depends_on_card_id` is the **blocker**.

  There is deliberately no `changeset/2`: rows are insert/delete only and are written by exactly
  one function, `Relay.Cards.set_dependencies/4`, the way `Schemas.SubTask` rows are written by
  `Relay.Cards.set_sub_tasks/2`. Ref resolution, the all-or-nothing unknown-ref rule and the
  cycle check all live there, because they are properties of the *set*, not of a single row.

  No `updated_at` — an edge is never edited, only created or dropped.
  """

  use Ecto.Schema

  schema "card_dependencies" do
    belongs_to :card, Schemas.Card
    belongs_to :depends_on_card, Schemas.Card

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
