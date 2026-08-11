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

  test "the scaffold sources are copied in before the scaffold is built", %{builder: builder} do
    # `mix relay.build_scaffold` reads `bin/relay` and `.claude/skills/relay-*`; copying them
    # after the build would produce an empty manifest, not an error.
    assert offset(builder, ~r/^COPY \.claude \.claude$/m) < offset(builder, ~r/^RUN mix relay\.build_scaffold$/m)
    assert offset(builder, ~r/^COPY bin bin$/m) < offset(builder, ~r/^RUN mix relay\.build_scaffold$/m)
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
