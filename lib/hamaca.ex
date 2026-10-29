defmodule Hamaca do
  @moduledoc """
  Hamaca keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.

  Each context (e.g. `Hamaca.Repo`, `Hamaca.Cards`, and future domain contexts)
  is its own `Boundary` sub-boundary; add new ones to `exports` below so the web
  layer can reach them. See `docs/adr/` for the architecture rules.
  """

  use Boundary,
    deps: [Schemas],
    exports: [
      Repo,
      Accounts,
      Accounts.GoogleTokenValidator,
      Accounts.AppleTokenValidator,
      Activity,
      Activity.LogSink,
      Activity.Pruner,
      AgentLog,
      Agents,
      ApiKeys,
      Attachments,
      Billing,
      Billing.Standing,
      BoardWatch,
      Boards,
      Brand,
      Cards,
      Config,
      Events,
      Examples,
      Flows,
      Flows.Document,
      Flows.Shape,
      Mailer,
      Markdown,
      Members,
      Presence,
      Push,
      Runs,
      Runs.Capacity,
      Runs.RunDetail,
      Runs.SchedulerSupervisor,
      Runs.Supervisor,
      Scaffold,
      Setup,
      StoryMap,
      Talk,
      Talk.PinReaper,
      Usage,
      Usage.Tracker,
      ValueStream,
      Votes
    ]
end
