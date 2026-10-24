defmodule Schemas do
  @moduledoc """
  Shared Ecto schemas (ADR 0002) — a top-level peer boundary depended on by
  both the domain (`Relay.*` contexts) and the web layer (`RelayWeb`).
  Schemas hold data shape and changesets; business logic stays in the
  contexts. Schemas may reference each other freely within this boundary.
  """

  use Boundary,
    deps: [],
    exports: [
      Activity,
      Agent,
      ApiKey,
      Attachment,
      BillingAccount,
      BillingNotice,
      BillingPaymentAttempt,
      Board,
      BoardSetupStep,
      Card,
      CardDependency,
      CardOwner,
      CardRejection,
      Comment,
      DeviceToken,
      Runner,
      Flow,
      Flow.Edge,
      Flow.Node,
      FlowVersion,
      Harness,
      HarnessUsage,
      HarnessUsage.PauseNow,
      HarnessUsage.Recheck,
      HarnessUsage.Rule,
      HarnessUsage.Window,
      Membership,
      NodeExecution,
      NodeJob,
      Release,
      Run,
      RunBranch,
      Scope,
      SetupMachine,
      Stage,
      StoryActivity,
      StoryStep,
      SubTask,
      TalkEvent,
      TalkSession,
      TalkTurn,
      User,
      UserApiToken,
      Vote
    ]
end
