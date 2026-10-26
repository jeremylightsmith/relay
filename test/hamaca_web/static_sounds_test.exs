defmodule HamacaWeb.StaticSoundsTest do
  use ExUnit.Case, async: true

  # RE399 — the browser tabs play the same "Job's done" horn as the iOS push, from a
  # web-playable copy served by Plug.Static.
  test "the web horn is served from a static path that exists on disk" do
    assert Hamaca.Push.web_sound_path() == "/sounds/keys_jingle.mp3"
    assert File.exists?(Path.join("priv/static", Hamaca.Push.web_sound_path()))
    assert "sounds" in HamacaWeb.static_paths()
  end
end
