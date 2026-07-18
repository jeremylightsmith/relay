defmodule Schemas.FlowVersion do
  @moduledoc """
  Immutable snapshot of a flow's versioned definition (isolation, nodes, edges) at a given
  `version`. Written by `Relay.Flows` in the same transaction as every definition-changing
  save; never edited. Rows have no `updated_at`. Every flow always has a snapshot row for its
  current version — the invariant the Runs engine relies on to pin a mid-run card to the
  definition it started on.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "flow_versions" do
    field :version, :integer
    field :isolation, Ecto.Enum, values: [:shared_clean, :exclusive]

    belongs_to :flow, Schemas.Flow

    embeds_many :nodes, Schemas.Flow.Node, on_replace: :delete
    embeds_many :edges, Schemas.Flow.Edge, on_replace: :delete

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  # Internal to Relay.Flows — snapshots are never edited after insert.
  def snapshot_changeset(version, attrs) do
    version
    |> cast(attrs, [:flow_id, :version, :isolation])
    |> validate_required([:flow_id, :version, :isolation])
    |> cast_embed(:nodes)
    |> cast_embed(:edges)
    |> unique_constraint([:flow_id, :version], name: :flow_versions_flow_id_version_index)
  end
end
