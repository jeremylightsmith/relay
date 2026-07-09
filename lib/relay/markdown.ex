defmodule Relay.Markdown do
  @moduledoc """
  Renders card long-form markdown (`description`, `spec`, `plan`) to sanitized
  HTML for display in the card drawer.

  MDEx renders the markdown with raw-HTML pass-through (`unsafe: true`) and then
  runs its HTML sanitizer (`MDEx.Document.default_sanitize_options/0`), so any
  agent- or human-authored markdown has dangerous tags (e.g. `<script>`) and
  their content stripped before it reaches the page. The result is wrapped as a
  `Phoenix.HTML.safe` value for direct `{...}` interpolation in HEEx — templates
  never call `raw/1` on it.
  """

  use Boundary, deps: []

  @doc """
  Render markdown to a sanitized `Phoenix.HTML.safe` value. `nil` renders to an
  empty (safe) string.
  """
  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: {:safe, ""}

  def to_html(markdown) when is_binary(markdown) do
    html =
      MDEx.to_html!(markdown,
        render: [unsafe: true],
        extension: [table: true],
        sanitize: MDEx.Document.default_sanitize_options()
      )

    {:safe, html}
  end
end
