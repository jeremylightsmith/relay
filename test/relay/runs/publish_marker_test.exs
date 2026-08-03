defmodule Relay.Runs.PublishMarkerTest do
  use ExUnit.Case, async: true

  alias Relay.Runs
  alias Relay.Runs.PublishMarker

  @moduletag :tmp_dir

  describe "version/1" do
    test "reads the executor_version out of a marker", %{tmp_dir: dir} do
      path = PublishMarker.write!(42, PublishMarker.path(dir))

      assert PublishMarker.version(path) == 42
    end

    test "is nil when the marker does not exist", %{tmp_dir: dir} do
      assert PublishMarker.version(Path.join(dir, "nope/published.json")) == nil
    end

    test "is nil when the marker is not JSON", %{tmp_dir: dir} do
      path = Path.join(dir, "published.json")
      File.write!(path, "{not json")

      assert PublishMarker.version(path) == nil
    end

    test "is nil when the key is missing or not an integer", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing.json")
      wrong = Path.join(dir, "wrong.json")
      File.write!(missing, ~s({"other": 1}))
      File.write!(wrong, ~s({"executor_version": "28"}))

      assert PublishMarker.version(missing) == nil
      assert PublishMarker.version(wrong) == nil
    end
  end

  test "write!/2 round-trips and re-writing the same version is byte-identical", %{tmp_dir: dir} do
    path = PublishMarker.path(dir)
    PublishMarker.write!(7, path)
    first = File.read!(path)
    PublishMarker.write!(7, path)

    assert File.read!(path) == first
    assert PublishMarker.version(path) == 7
  end

  test "latest_executor_version/0 is what the committed marker records" do
    # The value is read at COMPILE time; this asserts the compiled-in answer still matches the
    # file on disk, which is the only way the board can be trusted to name a fetchable version.
    assert Runs.latest_executor_version() ==
             PublishMarker.version(PublishMarker.path(File.cwd!()))
  end

  test "the Dockerfile copies .relay into the build stage before compiling, so the marker is not silently nil in prod" do
    # Compile-time embedding (@external_resource) means `mix compile` in the builder stage is
    # what bakes `latest_executor_version/0`'s answer into the release. If `.relay` never lands
    # in the build context, `PublishMarker.version/1` quietly returns nil (its documented
    # behaviour for "no file") and every deployed heartbeat reports `latest_executor_version:
    # null` — indistinguishable from "nothing published yet".
    dockerfile = File.read!("Dockerfile")
    [pre_compile, _] = String.split(dockerfile, ~r/^RUN mix compile$/m, parts: 2)

    assert pre_compile =~ ~r/^COPY \.relay \.relay$/m
  end
end
