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
    {json?, argv} = pop_json(argv)
    {to, args} = pop_to(argv)

    case dispatch(args, [json: json?], to) do
      {:ok, output} ->
        IO.puts(output)

      {:error, message} ->
        IO.puts(:stderr, message)
        exit({:shutdown, 1})
    end
  end

  defp dispatch(["board"], opts, _to), do: Relay.CLI.board(opts)
  defp dispatch(["card", ref], opts, _to), do: Relay.CLI.card(ref, opts)
  defp dispatch(["pull"], opts, _to), do: Relay.CLI.pull(opts)
  defp dispatch(["comment", ref, body], opts, _to), do: Relay.CLI.comment(ref, body, opts)
  defp dispatch(["move", ref, stage], opts, _to), do: Relay.CLI.move(ref, stage, opts)
  defp dispatch(["status", ref, status], opts, _to), do: Relay.CLI.status(ref, status, opts)
  defp dispatch(["needs-input", ref, question], opts, _to), do: Relay.CLI.needs_input(ref, question, opts)
  defp dispatch(["reject", ref, note], opts, to), do: Relay.CLI.reject(ref, note, opts, to)
  defp dispatch(["own", ref], opts, _to), do: Relay.CLI.own(ref, opts)
  defp dispatch(["release", ref], opts, _to), do: Relay.CLI.release(ref, opts)
  defp dispatch(_argv, _opts, _to), do: {:error, usage()}

  defp pop_json(argv), do: {"--json" in argv, argv -- ["--json"]}

  # `--to STAGE` (optional) picks the send-back target for `reject`.
  defp pop_to(argv) do
    case Enum.split_while(argv, &(&1 != "--to")) do
      {before, ["--to", stage | rest]} -> {stage, before ++ rest}
      {_before, _no_flag} -> {nil, argv}
    end
  end

  defp usage do
    """
    usage: mix relay <command> [--json]
      board                      show the board
      card REF                   show a card + timeline
      pull                       next AI card to work
      comment REF "text"         post a comment
      move REF STAGE             move to a stage (by name)
      status REF STATUS          set status (ready|working|needs_input|in_review)
      needs-input REF "question" flag needs_input with a question
      reject REF "note" [--to STAGE]  send the card back with a note
      own REF                    claim the card for the AI
      release REF                clear owners
    """
  end
end
