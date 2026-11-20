defmodule HamacaWeb.LiveSocketTransportTest do
  @moduledoc """
  The LiveSocket must stay on WebSocket — no LongPoll fallback.

  With `longPollFallbackMs` set, phoenix.js falls back to LongPoll on ANY error before a
  connection opens — including every reconnect after a laptop wake or a Wi-Fi blip — and the
  page then stays on LongPoll for its lifetime (and, if it never reached WebSocket, for the
  whole tab via `sessionStorage`). A LongPoll session dies server-side after ~15s without a
  client poll, so any main-thread stall (decoding a large image, a busy tab) ends in
  `410 session_gone`: the topbar flashes and the LiveView remounts, wiping whatever the user
  was typing. Reproduced in prod: a 35s stall remounts on LongPoll and is a no-op on
  WebSocket, which also reconnects on its own after a blip.
  """
  use ExUnit.Case, async: true

  @app_js Path.expand("../../assets/js/app.js", __DIR__)

  test "app.js does not enable the LongPoll fallback" do
    refute File.read!(@app_js) =~ ~r/^\s*longPollFallbackMs\s*:/m,
           "remove longPollFallbackMs from the LiveSocket options in assets/js/app.js " <>
             "(see this test's @moduledoc for why)"
  end
end
