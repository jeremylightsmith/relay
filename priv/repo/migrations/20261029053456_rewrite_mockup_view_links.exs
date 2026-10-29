defmodule Hamaca.Repo.Migrations.RewriteMockupViewLinks do
  use Ecto.Migration

  # RE487 — the RE370 mockup link `/attachments/:id/view` (`HamacaWeb.MockupViewerLive`) only
  # redirected to the board's mockup viewer (RE380), and its route is being deleted. Links to it
  # stored in card text, task bodies and comments are rewritten to that viewer URL first:
  # `/board/<slug>?card=<ref>&mockup=<id>`, always relative, host dropped.
  #
  # Only HTML attachments are rewritten: the old LiveView 404'd an image, so an image's `/view`
  # link has no viewer to point at. An unknown uuid is left byte-identical.
  #
  # The card ref format (board key + ref number, `Schemas.Card.format_ref/2`) and the HTML
  # content type are FROZEN here — a migration never calls app code that may change later.
  @html_type "text/html"

  @columns [
    {"cards", ~w(description spec plan acceptance_criteria)},
    {"sub_tasks", ~w(body)},
    {"comments", ~w(body)}
  ]

  def up, do: rewrite!(repo())

  # The old links are not restored: their route is gone, and the viewer URL works either way.
  def down, do: :ok

  @doc "The data rewrite `up` runs — also exactly what its test executes. Idempotent."
  @spec rewrite!(repo :: module()) :: :ok
  def rewrite!(repo) do
    lookup = lookup(repo)

    for {table, columns} <- @columns,
        column <- columns,
        {id, text} <- rows(repo, table, column) do
      rewritten = rewrite_text(text, lookup)
      if rewritten != text, do: write!(repo, table, column, id, rewritten)
    end

    :ok
  end

  @doc """
  Rewrites every `/attachments/<uuid>/view` link (optionally prefixed by the app's host) whose
  uuid is a key of `lookup` to `/board/<slug>?card=<ref>&mockup=<uuid>`. Pure.
  """
  @spec rewrite_text(String.t() | nil, %{String.t() => {slug :: String.t(), ref :: String.t()}}) ::
          String.t() | nil
  def rewrite_text(nil, _lookup), do: nil

  def rewrite_text(text, lookup) do
    Regex.replace(link(), text, fn match, id ->
      case Map.fetch(lookup, id) do
        {:ok, {slug, ref}} -> "/board/#{slug}?card=#{ref}&mockup=#{id}"
        :error -> match
      end
    end)
  end

  defp link,
    do: ~r"(?:https?://(?:hamaca\.app|relayboard\.fly\.dev))?/attachments/([0-9a-fA-F-]{36})/view"

  defp lookup(repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT a.id::text, b.slug, b.key, c.ref_number
        FROM attachments a
        JOIN cards c ON c.id = a.card_id
        JOIN boards b ON b.id = c.board_id
        WHERE a.content_type = $1
        """,
        [@html_type]
      )

    Map.new(rows, fn [id, slug, key, ref_number] -> {id, {slug, "#{key}#{ref_number}"}} end)
  end

  defp rows(repo, table, column) do
    %{rows: rows} =
      repo.query!(
        "SELECT id, #{column} FROM #{table} WHERE #{column} LIKE '%/attachments/%/view%' ORDER BY id"
      )

    Enum.map(rows, fn [id, text] -> {id, text} end)
  end

  defp write!(repo, table, column, id, text),
    do: repo.query!("UPDATE #{table} SET #{column} = $1 WHERE id = $2", [text, id])
end
