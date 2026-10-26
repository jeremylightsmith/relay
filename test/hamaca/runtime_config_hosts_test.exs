defmodule Hamaca.RuntimeConfigHostsTest do
  @moduledoc """
  RE480: `config/runtime.exs` parses `PHX_EXTRA_HOSTS` once into `:hamaca, :extra_hosts`, and
  the prod `check_origin` is built from that same list.

  `runtime.exs` reads the OS env, which a test must not write (ADR 0009). So each read runs
  `Config.Reader.read!/2` in a child `elixir` process whose environment is given by
  `System.cmd/3`'s `env:` — this VM's env is never touched, and the module stays async.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @runtime Path.join(@root, "config/runtime.exs")

  @base_env [
    {"DATABASE_URL", "ecto://u:p@localhost/db"},
    {"SECRET_KEY_BASE", String.duplicate("a", 64)},
    {"PHX_HOST", "hamaca.app"}
  ]

  @payload_open "<<CONFIG>>"
  @payload_close "<</CONFIG>>"

  # The config `runtime.exs` evaluates to for `env`, with `extra_hosts` as PHX_EXTRA_HOSTS
  # (`nil` unsets it in the child).
  defp read(env, extra_hosts) do
    script = """
    config = Config.Reader.read!(#{inspect(@runtime)}, env: #{inspect(env)})
    IO.write("\n#{@payload_open}" <> (config |> :erlang.term_to_binary() |> Base.encode64()) <> "#{@payload_close}\n")
    """

    {out, 0} =
      System.cmd("elixir", ["-e", script],
        cd: @root,
        env: @base_env ++ [{"PHX_EXTRA_HOSTS", extra_hosts}, {"PHX_SERVER", nil}]
      )

    # Logger lines (the prod block's APNs warning) share stdout and are written asynchronously, so
    # under a loaded suite they can land before OR after the payload — hence the sentinels.
    [_, payload] = Regex.run(~r/#{@payload_open}([A-Za-z0-9+\/=]+)#{@payload_close}/, out)
    payload |> Base.decode64!() |> :erlang.binary_to_term()
  end

  test "prod trims, downcases and drops blanks, and check_origin uses the same list" do
    config = read(:prod, " relayboard.fly.dev, WWW.hamaca.app ,")

    assert config[:hamaca][:extra_hosts] == ["relayboard.fly.dev", "www.hamaca.app"]

    assert config[:hamaca][HamacaWeb.Endpoint][:check_origin] ==
             ["//hamaca.app", "//relayboard.fly.dev", "//www.hamaca.app"]
  end

  test "prod with PHX_EXTRA_HOSTS unset has no extra hosts" do
    config = read(:prod, nil)

    assert config[:hamaca][:extra_hosts] == []
    assert config[:hamaca][HamacaWeb.Endpoint][:check_origin] == ["//hamaca.app"]
  end

  test "dev parses the list too, so the redirect can be exercised locally" do
    assert read(:dev, "relayboard.fly.dev")[:hamaca][:extra_hosts] == ["relayboard.fly.dev"]
  end

  test "PHX_EXTRA_HOSTS is read by exactly one System.get_env call" do
    source = File.read!(@runtime)

    assert length(Regex.scan(~r/"PHX_EXTRA_HOSTS"\s*\|>\s*System\.get_env|System\.get_env\(\s*"PHX_EXTRA_HOSTS"/, source)) ==
             1

    assert length(Regex.scan(~r/"PHX_EXTRA_HOSTS"/, source)) == 1
  end
end
