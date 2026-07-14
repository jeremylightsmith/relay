defmodule Relay do
  @moduledoc """
  Relay keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.

  Each context (e.g. `Relay.Repo`, `Relay.Mailer`, and future domain contexts)
  is its own `Boundary` sub-boundary; add new ones to `exports` below so the web
  layer can reach them. See `docs/adr/` for the architecture rules.
  """

  use Boundary,
    deps: [Schemas],
    exports: [
      Repo,
      Mailer,
      Accounts,
      Accounts.GoogleTokenValidator,
      Activity,
      AgentLog,
      ApiKeys,
      Attachments,
      BoardWatch,
      Boards,
      Cards,
      Events,
      Markdown,
      Members
    ]
end
