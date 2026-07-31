defmodule RelayWeb.ChangesetErrorsTest do
  @moduledoc """
  The shared changeset-error walk (RLY-241). Two callers depend on it — the API fallback
  controller renders 422/400 bodies from `messages/1`, the flow editor lists `leaf_messages/1`
  — and each one previously carried its own copy that broke on the other's input shape.
  """
  use Relay.DataCase, async: true

  alias RelayWeb.ChangesetErrors

  describe "messages/1" do
    test "flattens cast_embed errors instead of raising on the nested shape" do
      changeset =
        Schemas.Flow.changeset(%Schemas.Flow{}, %{
          key: "spec",
          board_id: 1,
          isolation: :shared_clean,
          nodes: [%{key: "a", type: :agent, max_retries: 0}],
          edges: []
        })

      messages = ChangesetErrors.messages(changeset)

      assert Enum.any?(messages, &(&1 =~ "nodes" and &1 =~ "must be greater than 0"))
    end

    # A failed enum cast carries `type: {:parameterized, {Ecto.Enum, %{...}}}` in its opts.
    # Interpolating by folding over every opt calls `to_string/1` on that tuple and raises,
    # which turned `PATCH /api/cards/:ref` with a bogus status into a 500.
    test "survives an enum cast error, whose opts carry a non-printable parameterized type" do
      changeset = Ecto.Changeset.cast(%Schemas.Card{}, %{"status" => "bogus"}, [:status])

      assert ["status is invalid"] = ChangesetErrors.messages(changeset)
    end

    test "interpolates the message's own placeholders" do
      changeset =
        %Schemas.Card{}
        |> Ecto.Changeset.cast(%{"title" => "x"}, [:title])
        |> Ecto.Changeset.validate_length(:title, min: 5)

      assert ["title should be at least 5 character(s)"] = ChangesetErrors.messages(changeset)
    end
  end

  describe "leaf_messages/1" do
    test "drops the field path so the editor can label its own fields" do
      changeset =
        Schemas.Flow.changeset(%Schemas.Flow{}, %{
          key: "spec",
          board_id: 1,
          isolation: :shared_clean,
          nodes: [%{key: "a", type: :agent, max_retries: 0}],
          edges: []
        })

      assert "must be greater than 0" in ChangesetErrors.leaf_messages(changeset)
    end
  end
end
