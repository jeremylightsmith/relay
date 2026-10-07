defmodule RelayWeb.TouchFieldSizeTest do
  @moduledoc """
  RE400 — iOS zooms the page into any focused field under 16px. On touch devices
  (`@media (hover: none) and (pointer: coarse)`) every input, textarea and select is sized by the
  one `--m-field` token, from an unlayered rule so it beats Tailwind's layered `text-[…]` /
  `textarea-sm` utilities. Desktop (fine pointer) never matches.
  """
  use ExUnit.Case, async: true

  @app_css Path.join([File.cwd!(), "assets", "css", "app.css"])
  @media "@media (hover: none) and (pointer: coarse)"

  defp css, do: File.read!(@app_css)

  # The body of the `{ … }` block that opens at `offset`, balancing nested braces.
  defp block_at(css, offset) do
    {open, _} = :binary.match(css, "{", scope: {offset, byte_size(css) - offset})
    rest = binary_part(css, open + 1, byte_size(css) - open - 1)
    take_block(rest, 1, [])
  end

  defp take_block(<<"}", _::binary>>, 1, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp take_block(<<"}", rest::binary>>, depth, acc), do: take_block(rest, depth - 1, ["}" | acc])
  defp take_block(<<"{", rest::binary>>, depth, acc), do: take_block(rest, depth + 1, ["{" | acc])
  defp take_block(<<c::utf8, rest::binary>>, depth, acc), do: take_block(rest, depth, [<<c::utf8>> | acc])

  defp coarse_block do
    css = css()

    case :binary.matches(css, @media) do
      [{offset, _}] -> block_at(css, offset)
      found -> flunk("app.css must open exactly one #{@media} block, found #{length(found)}")
    end
  end

  test "the RE393 :root scale block defines --m-field: 16px" do
    [block] = Regex.run(~r{/\* --- RE393 mobile type scale.*?\n:root \{.*?\n\}\n}s, css())
    assert block =~ "--m-field: 16px;"
  end

  test "the coarse-pointer block sizes input, textarea and select by --m-field, with no 16px literal" do
    block = coarse_block()

    rule =
      ~r/([^{}]+)\{\s*font-size:\s*var\(--m-field\);?\s*\}/
      |> Regex.scan(block, capture: :all_but_first)
      |> Enum.map(fn [selectors] -> selectors |> String.split(",") |> Enum.map(&String.trim/1) end)
      |> Enum.find(&(Enum.member?(&1, "input") and Enum.member?(&1, "textarea") and Enum.member?(&1, "select")))

    assert rule, "expected `input, textarea, select { font-size: var(--m-field) }` in:\n#{block}"
    refute block =~ "16px"
  end

  test "the coarse-pointer field rule is not inside any @layer block" do
    css = css()
    [{media_offset, _}] = :binary.matches(css, @media)

    # `@layer a, b;` statements open no block; only `@layer name { … }` can wrap the rule.
    for {layer_offset, _} <- :binary.matches(css, "@layer"),
        layer_offset < media_offset,
        css |> binary_part(layer_offset, media_offset - layer_offset) |> String.match?(~r/\A@layer[^;{]*\{/) do
      body = block_at(css, layer_offset)
      refute body =~ @media, "the #{@media} block must stay unlayered"
    end
  end
end
