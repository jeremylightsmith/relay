defmodule RelayWeb.Api.VersionController do
  @moduledoc """
  `GET /api/version` (RLY-177) — the git SHA the running app was built from.

  The Code flow merges to `main` but never deploys, so production silently lags and
  nothing surfaces it; at one point the deployed release was identified by checking
  whether `Schemas.Flow.Node` had a `foreach` field. `GIT_SHA` is baked at image build
  time (the `final` stage of the `Dockerfile`, fed by the `flyctl deploy --build-arg` in
  `.github/workflows/ci.yml`), so this is a **runtime** `System.get_env/1` read — a
  compile-time read would bake the builder's value into the release.

  Falls back to `"unknown"` rather than guessing: a local `mix phx.server` and any build
  without the arg should be honest, not misleading.

  Unauthenticated by design (it leaks nothing a deploy does not), but on the `:api`
  pipeline for consistency with the rest of `/api`.
  """
  use RelayWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      sha: System.get_env("GIT_SHA") || "unknown",
      built_at: System.get_env("BUILT_AT") || "unknown",
      version: to_string(Application.spec(:relay, :vsn) || "unknown")
    })
  end
end
