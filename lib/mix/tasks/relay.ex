defmodule Mix.Tasks.Relay do
  @shortdoc "Relay CLI — drive a Relay board from the terminal"
  @moduledoc """
  Work a Relay board over the REST API. Configure `RELAY_URL` and
  `RELAY_API_KEY`, then:

      mix relay board
      mix relay card RLY-12
      mix relay pull

  Add `--json` to any command for machine-readable output.
  """
  use Boundary, classify_to: Relay.CLI
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:req)
    {json?, args} = pop_json(argv)

    case dispatch(args, json: json?) do
      {:ok, output} ->
        IO.puts(output)

      {:error, message} ->
        IO.puts(:stderr, message)
        exit({:shutdown, 1})
    end
  end

  defp dispatch(["board"], opts), do: Relay.CLI.board(opts)
  defp dispatch(["card", ref], opts), do: Relay.CLI.card(ref, opts)
  defp dispatch(["pull"], opts), do: Relay.CLI.pull(opts)
  defp dispatch(_argv, _opts), do: {:error, usage()}

  defp pop_json(argv), do: {"--json" in argv, argv -- ["--json"]}

  defp usage do
    "usage: mix relay <board | card REF | pull> [--json]"
  end
end
