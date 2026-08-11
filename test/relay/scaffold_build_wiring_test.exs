defmodule Relay.ScaffoldBuildWiringTest do
  @moduledoc """
  Guards the `Dockerfile` wiring the whole served-scaffold feature rests on (RE304, ADR 0010).

  A Mix release ships `priv/` but ships neither `bin/` nor `.claude/`, so
  `RUN mix relay.build_scaffold` is the ONLY thing that puts anything in `priv/scaffold/` for
  the image to serve. If that line is dropped, reordered after `RUN mix release`, or the
  `COPY .claude` / `COPY bin` lines drift below it, the release ships an empty scaffold and the
  failure is completely silent in production: `GET /api/scaffold` answers 503
  `scaffold_unavailable`, every heartbeat advertises `latest_executor_version: null` (which the
  executor reads as "never auto-update", indistinguishable from "nothing published"), and
  `/relay-setup` cannot bootstrap a project at all. Nothing else in the suite would fail.
  """
  use ExUnit.Case, async: true

  setup_all do
    [builder | _] =
      "Dockerfile"
      |> File.read!()
      |> String.split(~r/^FROM \$\{RUNNER_IMAGE\} AS final$/m)

    {:ok, builder: builder}
  end

  test "the builder stage builds the scaffold", %{builder: builder} do
    assert builder =~ ~r/^RUN mix relay\.build_scaffold$/m
  end

  test "EVERY scaffold source is copied in before the scaffold is built", %{builder: builder} do
    # Derived from Scaffold.items/0, never a hand-listed pair. This test used to name `.claude`
    # and `bin` literally, so adding `relay.md` to items/0 left the Dockerfile a source short and
    # the suite green — `build!/2` raises on the missing file and the DEPLOY is what failed.
    # Anything added to items/0 from now on fails here instead, which is the whole point of the
    # file: CI pins MIX_ENV=test and never runs the Dockerfile.
    build_at = offset(builder, ~r/^RUN mix relay\.build_scaffold$/m)

    for source <- scaffold_copy_sources() do
      copy = ~r/^COPY #{Regex.escape(source)} (#{Regex.escape(source)}|\.\/)$/m

      assert offset(builder, copy) < build_at,
             "Dockerfile must `COPY #{source}` before `RUN mix relay.build_scaffold` — " <>
               "#{source} holds a Scaffold.items/0 entry, and build!/2 raises without it"
    end
  end

  # The top-level path each served item arrives by: `bin/relay` -> `bin`, a skill -> `.claude`,
  # `relay.md` -> `relay.md` (a root file is copied by name).
  defp scaffold_copy_sources do
    Relay.Scaffold.items()
    |> Enum.map(&(&1 |> Path.split() |> hd()))
    |> Enum.uniq()
  end

  test "the scaffold is built before the release bundles priv/", %{builder: builder} do
    assert offset(builder, ~r/^RUN mix relay\.build_scaffold$/m) < offset(builder, ~r/^RUN mix release$/m)
  end

  # The task copies files and hashes bytes; it needs `compile`, never `app.config`. `app.config`
  # loads `config/runtime.exs` whenever that file exists, and ours raises without `DATABASE_URL`
  # under MIX_ENV=prod — so with `app.config` the prod build only worked because
  # `COPY config/runtime.exs` happens to sit BELOW the task, and hoisting that COPY (a routine
  # tidy) would have broken `fly deploy` with a missing-database error from a task that needs no
  # database. CI cannot catch that: the workflow pins MIX_ENV=test, so only a real deploy
  # exercises the Dockerfile. Pin the decoupling instead of the accident.
  test "building the scaffold does not depend on runtime config" do
    source = File.read!("lib/mix/tasks/relay.build_scaffold.ex")

    refute source =~ "Mix.Task.run(\"app.config\")"
    assert source =~ "Mix.Task.run(\"compile\")"
  end

  defp offset(text, regex) do
    case Regex.run(regex, text, return: :index) do
      [{start, _len} | _] -> start
      nil -> flunk("Dockerfile builder stage is missing a line matching #{inspect(regex)}")
    end
  end
end
