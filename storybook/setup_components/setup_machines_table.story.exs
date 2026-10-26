defmodule Storybook.SetupComponents.SetupMachinesTable do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.SetupComponents.setup_machines_table/1
  def render_source, do: :function

  # RE446, card mockup "Payoff — first card turns violet, Settings → Setup, connect a machine",
  # frame C: "Machines on this board". Rows are `Hamaca.Setup.machines/1` rows: the board's own
  # setup first, then each connected machine.
  def variations do
    [
      %Variation{
        id: :board_and_member,
        description: "C · the finished board machine and a member's machine on step 4",
        attributes: %{
          id: "setup-machines",
          machines: [
            %{
              id: :board,
              machine: "jl-mbp",
              person: "Jeremy",
              key_last_four: "9f3a",
              harnesses: [%{cli: "claude", signed_in: true}],
              finished?: true,
              progress: "7/7"
            },
            %{
              id: 12,
              machine: nil,
              person: "Sam",
              key_last_four: "4c1d",
              harnesses: [],
              finished?: false,
              progress: "4 install"
            }
          ]
        }
      },
      %Variation{
        id: :signed_out_and_revoked,
        description: "A signed-out harness and a revoked key",
        attributes: %{
          id: "setup-machines",
          machines: [
            %{
              id: 7,
              machine: "build-box",
              person: "Sam",
              key_last_four: nil,
              harnesses: [%{cli: "claude", signed_in: true}, %{cli: "codex", signed_in: false}],
              finished?: true,
              progress: "6/6"
            }
          ]
        }
      }
    ]
  end
end
