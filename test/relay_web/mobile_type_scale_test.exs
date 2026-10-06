defmodule RelayWeb.MobileTypeScaleTest do
  @moduledoc """
  RE393: the embed-only mobile type scale (`--m-*`) is defined once in app.css and
  mirrored verbatim into storybook.css (Storybook does not load app.css). The mirror is
  the one sanctioned duplicate, so this pins the two blocks byte-identical.
  """
  use ExUnit.Case, async: true

  @scale ~r{/\* --- RE393 mobile type scale \(embed only\) ---.*?\n:root \{.*?\n\}\n}s

  defp scale_block(path) do
    [block] = Regex.run(@scale, File.read!(path))
    block
  end

  test "storybook.css mirrors app.css's --m-* block byte-for-byte" do
    app = scale_block("assets/css/app.css")

    assert app =~ "--m-large-title: 34px;"
    assert app =~ "--m-target: 44px;"
    assert scale_block("assets/css/storybook.css") == app
  end
end
