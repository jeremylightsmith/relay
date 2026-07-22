defmodule Relay.Runs.PlanTasks do
  @moduledoc """
  Parses a card's `plan` into the sub_task list a `foreach` node iterates
  (W13 / RLY-139). The format is the one `/write-plan` already mandates:
  `### Task N: <name>` headings, in document order, title = the heading text.
  Pure and total — a plan with no headings yields `[]`, which makes the first
  `foreach` guard evaluate `:foreach_exhausted` and the run proceed straight
  past the loop rather than iterate on nothing.
  """

  # Anchored at line start (multiline) so a "### Task 1:" mentioned mid-sentence
  # in prose is not mistaken for a heading.
  #
  # Two to four hashes, because the heading LEVEL is prose, not a contract (RLY-165). The
  # parser used to demand exactly three; `/write-plan` emits two about as often, and the first
  # live Code dogfood parsed to [] for that reason alone. A single `#` is excluded on purpose —
  # that is the plan's own document title, not a task.
  #
  # The separator after the number is likewise prose, not a contract (RLY-206/RLY-209): accept
  # a colon, em-dash, en-dash, or hyphen. `/write-plan` kept emitting `## Task N — <name>`
  # (em-dash); demanding a colon silently yielded [] and parked the card in needs_input. The
  # `u` flag is required so the multibyte dashes in the class match as characters, not bytes.
  @heading ~r/^\#{2,4}[ \t]+Task[ \t]+\d+[ \t]*[-:—–][ \t]*(?<title>\S.*?)[ \t]*$/mu

  @spec parse(String.t() | nil) :: [%{title: String.t()}]
  def parse(nil), do: []

  def parse(plan) when is_binary(plan) do
    @heading
    |> Regex.scan(plan, capture: :all_names)
    |> Enum.map(fn [title] -> %{title: title} end)
  end
end
