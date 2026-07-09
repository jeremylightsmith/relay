defmodule RelayWeb.DocsHTML do
  @moduledoc "Templates for the public docs pages (see the `docs_html` directory)."
  use RelayWeb, :html

  embed_templates "docs_html/*"
end
