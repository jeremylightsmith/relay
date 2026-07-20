defmodule Relay.DeploySHAWiringTest do
  @moduledoc """
  Guards the wiring `GET /api/version` depends on. An `ARG` declared only in the `builder`
  stage is invisible in `final` (which copies just the release artifact), so a version
  endpoint can pass every unit test and still report "unknown" in production.
  """
  use ExUnit.Case, async: true

  test "the Dockerfile declares GIT_SHA in the final stage, not only the builder" do
    [_builder, final] =
      "Dockerfile"
      |> File.read!()
      |> String.split(~r/^FROM \$\{RUNNER_IMAGE\} AS final$/m)

    assert final =~ ~r/^ARG GIT_SHA$/m
    assert final =~ ~r/^ENV GIT_SHA=\$\{GIT_SHA\}$/m
  end

  test "the Dockerfile declares BUILT_AT in the final stage, not only the builder" do
    [_builder, final] =
      "Dockerfile"
      |> File.read!()
      |> String.split(~r/^FROM \$\{RUNNER_IMAGE\} AS final$/m)

    assert final =~ ~r/^ARG BUILT_AT$/m
    assert final =~ ~r/^ENV BUILT_AT=\$\{BUILT_AT\}$/m
  end

  test "the deploy workflow passes the commit SHA as a build arg" do
    assert File.read!(".github/workflows/ci.yml") =~ "--build-arg GIT_SHA=${{ github.sha }}"
  end

  test "the deploy workflow passes the commit timestamp as a build arg" do
    assert File.read!(".github/workflows/ci.yml") =~
             "--build-arg BUILT_AT=${{ github.event.head_commit.timestamp }}"
  end
end
