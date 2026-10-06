defmodule RelayWeb.StaticSoundsTest do
  use ExUnit.Case, async: true

  # RE399 — the browser tabs play the same "Job's done" horn as the iOS push, from a
  # web-playable copy served by Plug.Static.
  test "the web horn is served from a static path that exists on disk" do
    assert Relay.Push.web_sound_path() == "/sounds/jobs_done.mp3"
    assert File.exists?(Path.join("priv/static", Relay.Push.web_sound_path()))
    assert "sounds" in RelayWeb.static_paths()
  end
end
