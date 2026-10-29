# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Hamaca.Repo.Migrations.RewriteMockupViewLinks) do
  "priv/repo/migrations/*_rewrite_mockup_view_links.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Hamaca.Migrations.RewriteMockupViewLinksTest do
  @moduledoc """
  RE487 — the RE370 mockup link `/attachments/:id/view` is retired, so links to it stored in card
  text, task bodies and comments are rewritten to the board viewer URL
  (`/board/<slug>?card=<ref>&mockup=<id>`) before the route is deleted. Rows are read with raw
  SQL, as the migration writes them.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Repo
  alias Hamaca.Repo.Migrations.RewriteMockupViewLinks, as: Migration

  setup do
    board = insert(:board, slug: "acme", key: "AC")
    stage = insert(:stage, board: board)
    card = insert(:card, stage: stage, ref_number: 7)
    mockup = insert(:attachment, card: card, content_type: "text/html", filename: "home.html")
    image = insert(:attachment, card: card, content_type: "image/png")

    %{card: card, stage: stage, id: mockup.id, image_id: image.id, map: %{mockup.id => {"acme", "AC7"}}}
  end

  # Scenario 1
  test "rewrites absolute and relative links to the board viewer URL", %{id: id, map: map} do
    assert Migration.rewrite_text("See https://hamaca.app/attachments/#{id}/view and /attachments/#{id}/view.", map) ==
             "See /board/acme?card=AC7&mockup=#{id} and /board/acme?card=AC7&mockup=#{id}."
  end

  # Scenario 2
  test "drops the relayboard.fly.dev host too", %{id: id, map: map} do
    assert Migration.rewrite_text("https://relayboard.fly.dev/attachments/#{id}/view", map) ==
             "/board/acme?card=AC7&mockup=#{id}"
  end

  # Scenario 3
  test "leaves an unknown uuid byte-identical and passes nil through", %{map: map} do
    u = Ecto.UUID.generate()

    assert Migration.rewrite_text("x /attachments/#{u}/view y", map) == "x /attachments/#{u}/view y"
    assert Migration.rewrite_text(nil, map) == nil
  end

  test "leaves a non-uuid id alone", %{map: map} do
    assert Migration.rewrite_text("x /attachments/abc/view y", map) == "x /attachments/abc/view y"
  end

  # Scenario 4
  test "rewrites card text, comment bodies and task bodies in place", %{card: card, id: id} do
    set!("cards", card.id, "description", "Mockup: /attachments/#{id}/view")
    set!("cards", card.id, "spec", "Raw file: /attachments/#{id}")
    comment = insert(:comment, card: card, body: "Look https://hamaca.app/attachments/#{id}/view now")
    task = insert(:sub_task, card: card, body: "Match /attachments/#{id}/view")

    assert Migration.rewrite!(Repo) == :ok

    viewer = "/board/acme?card=AC7&mockup=#{id}"
    assert get!("cards", card.id, "description") == "Mockup: #{viewer}"
    assert get!("comments", comment.id, "body") == "Look #{viewer} now"
    assert get!("sub_tasks", task.id, "body") == "Match #{viewer}"
    assert get!("cards", card.id, "spec") == "Raw file: /attachments/#{id}"
  end

  test "rewrites plan and acceptance_criteria too", %{card: card, id: id} do
    set!("cards", card.id, "plan", "/attachments/#{id}/view")
    set!("cards", card.id, "acceptance_criteria", "/attachments/#{id}/view")

    Migration.rewrite!(Repo)

    assert get!("cards", card.id, "plan") == "/board/acme?card=AC7&mockup=#{id}"
    assert get!("cards", card.id, "acceptance_criteria") == "/board/acme?card=AC7&mockup=#{id}"
  end

  test "leaves an image attachment's /view link untouched", %{card: card, image_id: image_id} do
    text = "Shot: /attachments/#{image_id}/view"
    set!("cards", card.id, "description", text)

    Migration.rewrite!(Repo)

    assert get!("cards", card.id, "description") == text
  end

  # Scenario 5
  test "a second run is a no-op and a card with no links keeps its updated_at", %{card: card, stage: stage, id: id} do
    set!("cards", card.id, "description", "/attachments/#{id}/view")
    comment = insert(:comment, card: card, body: "https://hamaca.app/attachments/#{id}/view")
    task = insert(:sub_task, card: card, body: "/attachments/#{id}/view")
    plain = insert(:card, stage: stage, description: "no links here")
    plain_updated_at = get!("cards", plain.id, "updated_at")

    Migration.rewrite!(Repo)

    cells = [{"cards", card.id, "description"}, {"comments", comment.id, "body"}, {"sub_tasks", task.id, "body"}]
    before = for {table, row, col} <- cells, do: get!(table, row, col)

    Migration.rewrite!(Repo)

    assert for({table, row, col} <- cells, do: get!(table, row, col)) == before
    assert get!("cards", plain.id, "updated_at") == plain_updated_at
  end

  defp set!(table, id, column, value), do: Repo.query!("UPDATE #{table} SET #{column} = $1 WHERE id = $2", [value, id])

  defp get!(table, id, column) do
    %{rows: [[value]]} = Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [id])
    value
  end
end
