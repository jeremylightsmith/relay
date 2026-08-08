defmodule RelayWeb.Api.VersionControllerTest do
  # async: true despite mutating `GIT_SHA` — the OS process environment is a global stronger than
  # the `Application.put_env/3` ADR 0009 rule 1 forbids, so it needs an explicit reason.
  # Safe here because the reader and the writers are both contained: the sole runtime reader of
  # `GIT_SHA` is `RelayWeb.Api.VersionController.show/2`, this is the sole module that mutates it,
  # and it is the only module that issues a live `GET /api/version` (the other two hits are a
  # docstring and a docs-string assertion). Tests within one module are serialized, so these three
  # cannot race each other. **Re-check this the moment a second test hits `/api/version`** — at
  # that point the env var needs a real seam (or this module drops out of the async pool).
  use RelayWeb.ConnCase, async: true

  setup do
    original = System.get_env("GIT_SHA")

    on_exit(fn ->
      if original, do: System.put_env("GIT_SHA", original), else: System.delete_env("GIT_SHA")
    end)

    :ok
  end

  test "reports the baked SHA", %{conn: conn} do
    System.put_env("GIT_SHA", "0123456789abcdef0123456789abcdef01234567")

    body = conn |> get(~p"/api/version") |> json_response(200)

    assert body["sha"] == "0123456789abcdef0123456789abcdef01234567"
    assert body["version"] =~ ~r/\d+\.\d+\.\d+/
  end

  test "is honest rather than misleading when built with no GIT_SHA", %{conn: conn} do
    System.delete_env("GIT_SHA")

    assert conn |> get(~p"/api/version") |> json_response(200) |> Map.fetch!("sha") == "unknown"
  end

  test "needs no board key — it leaks nothing a deploy does not", %{conn: conn} do
    assert conn |> get(~p"/api/version") |> json_response(200)
  end
end
