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
      ApiKey,
      Attachment,
      Board,
      Card,
      CardOwner,
      CardRejection,
      Comment,
      DeviceToken,
      Executor,
      Flow,
      FlowVersion,
      Membership,
      NodeExecution,
      NodeJob,
      Run,
      Scope,
      Stage,
      SubTask,
      User,
      UserApiToken
    ]
end
