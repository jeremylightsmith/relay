defmodule Relay.Repo.Migrations.BackfillBoardKeysTwoLetters do
  use Ecto.Migration

  import Ecto.Query

  # RLY-230: card keys become exactly-2-letter board prefixes. Backfill every existing board to
  # the first two A-Z letters of its name (uppercased), fallback "RL". The derivation is inlined
  # here (`derive_key/1`, not a call into Relay.Boards) so this migration stays frozen against
  # later code changes.
  def up do
    for {id, name} <- repo().all(from(b in "boards", select: {b.id, b.name})) do
      repo().update_all(
        from(b in "boards", where: b.id == ^id),
        set: [key: derive_key(name)]
      )
    end
  end

  # The old variable-length keys are not recoverable and not worth reconstructing.
  def down, do: :ok

  # Public + pure so the backfill rule is unit-testable without the migrator's Runner context
  # (`Ecto.Migration.repo/0` -- which `up/0` uses -- requires it). Frozen: a self-contained copy of
  # the RLY-230 derivation rule, deliberately NOT a call into `Relay.Boards.derive_key/1`.
  def derive_key(name) do
    case name
         |> to_string()
         |> String.upcase()
         |> String.replace(~r/[^A-Z]/, "")
         |> String.slice(0, 2) do
      <<_::binary-size(2)>> = key -> key
      _ -> "RL"
    end
  end
end
