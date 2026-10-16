defmodule RelayWeb.InstallScript do
  @moduledoc """
  The board's install script (RE443), served at `GET /b/:slug/install` and piped into `sh`. A
  POSIX `sh` template (`install_script.sh.eex`) compiled into `render/2`: it preflights through
  `POST /api/setup/preflight`, writes the Relay files only once that passes, then reports
  `POST /api/setup/installed`.

  The output is executed, so only trusted values reach it: the configured base URL (the caller
  passes `RelayWeb.Endpoint.url/0`, never the request's Host) and a slug the controller already
  checked against `Schemas.Board.slug_format/0`, both single-quoted for `sh` regardless. The
  local check ids come from `Relay.Setup.preflight_checks/0` and the CLIs it looks for from
  `Relay.Setup.onboarding_llms/0`, so the script never re-types either list; the `relay.md` pointer
  line comes from `Relay.Setup.pointer_line/0`. It downloads only `./relay` and lets
  `./relay update` lay down the other Relay files under the LLM's skill dir (RE457).
  """

  alias Relay.Setup

  require EEx

  @template Path.join(__DIR__, "install_script.sh.eex")
  @external_resource @template

  EEx.function_from_file(:defp, :template, @template, [:assigns])

  @doc "The install script for `slug` on the board at `base_url` (a trailing `/` is trimmed)."
  @spec render(String.t(), String.t()) :: String.t()
  def render(base_url, slug) when is_binary(base_url) and is_binary(slug) do
    template(
      base_url: String.trim_trailing(base_url, "/"),
      slug: slug,
      check_ids: Enum.map(Setup.preflight_checks(), & &1.id),
      clis: Enum.map(Setup.onboarding_llms(), &sh_quote(&1.cli)),
      python3_fix: Setup.python3_fix(),
      pointer_line: Setup.pointer_line()
    )
  end

  # Single-quotes `value` for sh: the only character that needs care inside '…' is ' itself.
  defp sh_quote(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"
end
