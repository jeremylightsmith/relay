defmodule RelayWeb.SetupComponentsTest do
  @moduledoc "RE443 task 4: `RelayWeb.SetupComponents.setup_checklist/1` — one marker per step state."
  use Relay.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Setup
  alias RelayWeb.SetupComponents
  alias Schemas.BoardSetupStep

  # A real checklist with its first six top-level steps forced into each of the six statuses,
  # in the order step 1 done, 2 active, 3 waiting, 4 failed, 5 pending, 6 skipped.
  defp every_state_checklist do
    {:ok, board} =
      Boards.create_board(insert(:user), %{name: "S", slug: unique_slug("setup"), template: "bare-minimum"})

    [pending, active, waiting, done, failed, skipped] = BoardSetupStep.statuses()
    top_ids = for %{parent: nil, id: id} <- Setup.steps(), do: id
    by_step = Map.new(Enum.zip(top_ids, [done, active, waiting, failed, pending, skipped]))

    checklist = Setup.checklist(board)

    steps =
      Enum.map(checklist.steps, fn step ->
        case by_step[step.id] do
          nil -> step
          :waiting -> %{step | status: :waiting, evidence: "preflight passed 14:10 · jl-mbp"}
          :failed -> %{step | status: :failed, evidence: "preflight failed 14:07", error: "Preflight stopped"}
          status -> %{step | status: status}
        end
      end)

    %{checklist | steps: steps}
  end

  defp marker(doc, step_id) do
    [marker] = doc |> LazyHTML.query("#c-step-#{step_id} > .setup-marker-col > .setup-marker") |> Enum.to_list()
    {marker |> LazyHTML.text() |> String.trim(), marker |> LazyHTML.attribute("style") |> List.first()}
  end

  # Scenario 11
  test "renders one marker per step state" do
    checklist = every_state_checklist()
    html = render_component(&SetupComponents.setup_checklist/1, id: "c", checklist: checklist)
    doc = LazyHTML.from_fragment(html)

    {text, style} = marker(doc, "1")
    assert text == "✓"
    assert style =~ "background:var(--color-success)"

    {text, style} = marker(doc, "2")
    assert text == "2"
    assert style =~ "background:var(--color-primary)"
    assert style =~ "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-primary) 18%, var(--color-base-100))"

    {_text, style} = marker(doc, "3")
    assert style =~ "box-shadow:0 0 0 4px"
    assert doc |> LazyHTML.query("#c-step-3 .setup-evidence.animate-pulse") |> Enum.count() == 1

    {text, style} = marker(doc, "4")
    assert text == "!"
    assert style =~ "background:var(--color-error)"

    {text, style} = marker(doc, "5")
    assert text == "5"
    assert style =~ "border:1.5px solid var(--color-base-300)"
    refute style =~ "dashed"

    {_text, style} = marker(doc, "6")
    assert style =~ "border-style:dashed"

    [tag] = doc |> LazyHTML.query("#c-step-5 .setup-actor-tag") |> Enum.to_list()
    assert tag |> LazyHTML.text() |> String.trim() == "AI · terminal"
    assert tag |> LazyHTML.attribute("style") |> List.first() =~ "var(--color-secondary)"
  end

  # Scenario 11
  test "read-only mode renders no button and no input" do
    html =
      render_component(&SetupComponents.setup_checklist/1,
        id: "c",
        checklist: every_state_checklist(),
        mode: :read_only,
        token: "relay_secret",
        install_command: "curl -fsSL http://x/b/s/install | sh"
      )

    doc = LazyHTML.from_fragment(html)
    assert doc |> LazyHTML.query("button") |> Enum.count() == 0
    assert doc |> LazyHTML.query("input") |> Enum.count() == 0
    refute html =~ "relay_secret"
    refute html =~ "curl -fsSL"
  end
end
