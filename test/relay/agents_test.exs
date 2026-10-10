defmodule Relay.AgentsTest do
  @moduledoc """
  RE433 — every board owns harnesses (a CLI's command template + its closed model list) and
  named agents (harness + model), one of them the board default. Flow nodes name an agent via
  `llm`.
  """
  use Relay.DataCase, async: true

  alias Relay.Agents
  alias Relay.Repo
  alias Schemas.Agent
  alias Schemas.Flow

  defp seeded_board do
    board = insert(:board)
    :ok = Agents.ensure_seeded!(board)
    Repo.reload!(board)
  end

  defp harness(board, key), do: Enum.find(Agents.list_harnesses(board), &(&1.key == key))
  defp agent(board, name), do: Enum.find(Agents.list_agents(board), &(&1.name == name))

  defp gemini_pro(board) do
    gemini = harness(board, "gemini-cli")

    {:ok, pro} =
      Agents.create_agent(board, %{"name" => "Gemini Pro", "harness_id" => gemini.id, "model" => "gemini-2.5-pro"})

    {gemini, pro}
  end

  defp pi_attrs(name), do: %{"name" => name, "command" => "pi -p {prompt} --model {model}", "models" => "qwen3-coder"}

  defp agent_node(key, llm), do: %Flow.Node{key: key, type: :agent, run: "/x {ref}", llm: llm}

  defp put_flow!(board, key, nodes), do: insert(:flow, board: board, key: key, nodes: nodes, edges: [])

  describe "ensure_seeded!/1" do
    # Scenario 1
    test "seeds the three harnesses and three Claude agents with Claude Opus default, idempotently" do
      board = insert(:board)

      assert :ok = Agents.ensure_seeded!(board)
      assert :ok = Agents.ensure_seeded!(board)

      harnesses = Agents.list_harnesses(board)
      assert Enum.map(harnesses, & &1.name) == ["Claude Code", "Codex", "Gemini CLI"]
      assert Enum.map(harnesses, & &1.key) == ["claude-code", "codex", "gemini-cli"]

      agents = Agents.list_agents(board)
      assert Enum.map(agents, & &1.name) == ["Claude Opus", "Claude Sonnet", "Claude Haiku"]
      assert Enum.map(agents, & &1.model) == ["opus", "sonnet", "haiku"]
      assert Enum.all?(agents, &(&1.harness.key == "claude-code"))

      assert Agents.default_agent(board).name == "Claude Opus"
      assert length(harnesses) == 3 and length(agents) == 3
    end

    test "a board that already has agents keeps its agents and default untouched" do
      board = seeded_board()
      sonnet = agent(board, "Claude Sonnet")
      {:ok, _} = Agents.set_default_agent(board, sonnet)

      :ok = Agents.ensure_seeded!(board.id)

      assert length(Agents.list_agents(board)) == 3
      assert Agents.default_agent(board).name == "Claude Sonnet"
    end

    test "seed_harnesses/0 carries the exact seed commands, in order" do
      [claude, codex, gemini] = Agents.seed_harnesses()

      assert claude.key == Agents.default_harness_key()
      assert claude.models == ["opus", "sonnet", "haiku"]
      assert claude.session_id_path == ".session_id"
      assert claude.signed_in_check == "claude auth status"
      assert codex.command =~ "codex exec --json --model {model} --cd {worktree}"
      assert codex.session_id_path == ".thread_id"
      assert gemini.command == "gemini -p {prompt} --model {model}"
      assert gemini.resume_command == nil and gemini.session_id_path == nil and gemini.signed_in_check == nil
    end
  end

  # Scenario 2
  test "create_board/2 seeds the harnesses, the agents, the default and still the code flow" do
    {:ok, board} = Relay.Boards.create_board(insert(:user), %{name: "Agents board"})

    assert Enum.map(Agents.list_harnesses(board), & &1.key) == ["claude-code", "codex", "gemini-cli"]
    assert Enum.map(Agents.list_agents(board), & &1.name) == ["Claude Opus", "Claude Sonnet", "Claude Haiku"]
    assert Agents.default_agent(board).name == "Claude Opus"
    assert %Flow{key: "code"} = Relay.Flows.get_flow(board, "code")
  end

  describe "create_agent/2" do
    # Scenario 3
    test "refuses a model outside the harness's list" do
      board = seeded_board()
      codex = harness(board, "codex")

      assert {:error, cs} =
               Agents.create_agent(board, %{"name" => "Codex Mini", "harness_id" => codex.id, "model" => "opus"})

      assert "is not one of Codex's models" in errors_on(cs).model

      assert {:ok, %Agent{name: "Codex Mini"} = mini} =
               Agents.create_agent(board, %{"name" => "Codex Mini", "harness_id" => codex.id, "model" => "gpt-6-sol"})

      assert mini.harness.key == "codex"
    end

    # Scenario 4
    test "refuses a name already used on the board" do
      board = seeded_board()
      claude = harness(board, "claude-code")

      assert {:error, cs} =
               Agents.create_agent(board, %{"name" => "Claude Opus", "harness_id" => claude.id, "model" => "opus"})

      assert "is already used on this board" in errors_on(cs).name
    end

    test "refuses a harness from another board" do
      board = seeded_board()
      other = seeded_board()

      assert {:error, cs} =
               Agents.create_agent(board, %{
                 "name" => "Stray",
                 "harness_id" => harness(other, "codex").id,
                 "model" => "gpt-6-sol"
               })

      assert errors_on(cs).harness_id != []
    end
  end

  describe "red?/1 and harness updates" do
    # Scenario 5
    test "dropping a model an agent uses succeeds and turns that agent red" do
      board = seeded_board()
      {gemini, _pro} = gemini_pro(board)

      assert {:ok, h} = Agents.update_harness(gemini, %{"models" => "gemini-2.5-flash"})
      assert h.models == ["gemini-2.5-flash"]

      assert Agents.red?(agent(board, "Gemini Pro"))
      refute Agents.red?(agent(board, "Claude Opus"))
    end

    # Scenario 6
    test "models are trimmed, blanks dropped, duplicates and empties refused" do
      gemini = harness(seeded_board(), "gemini-cli")

      assert {:error, cs} = Agents.update_harness(gemini, %{"models" => " a, b ,, b"})
      assert ~s(has duplicate model "b") in errors_on(cs).models

      assert {:error, cs} = Agents.update_harness(gemini, %{"models" => " , "})
      assert "can't be blank" in errors_on(cs).models

      assert {:ok, h} = Agents.update_harness(gemini, %{"models" => "a, b"})
      assert h.models == ["a", "b"]
    end

    # Scenario 7
    test "command templates are validated" do
      gemini = harness(seeded_board(), "gemini-cli")

      assert {:error, cs} = Agents.update_harness(gemini, %{"command" => "pi --model {model}"})
      assert "must contain {prompt}" in errors_on(cs).command

      assert {:error, cs} = Agents.update_harness(gemini, %{"command" => "pi -p {prompt} {bogus}"})
      assert "unknown placeholder {bogus}" in errors_on(cs).command

      assert {:error, cs} = Agents.update_harness(gemini, %{"command" => "pi -p {prompt} [--x {model}"})
      assert "has an unbalanced [ … ] segment" in errors_on(cs).command

      assert {:error, cs} = Agents.update_harness(gemini, %{"session_id_path" => "session_id"})
      assert "must be a dot path like .session_id" in errors_on(cs).session_id_path
    end

    test "a resume command must carry {prompt} and {session}; nested segments are refused" do
      gemini = harness(seeded_board(), "gemini-cli")

      assert {:error, cs} = Agents.update_harness(gemini, %{"resume_command" => "g -p {prompt}"})
      assert "must contain {session}" in errors_on(cs).resume_command

      assert {:error, cs} = Agents.update_harness(gemini, %{"command" => "g -p {prompt} [a [b {model}]]"})
      assert "has an unbalanced [ … ] segment" in errors_on(cs).command

      assert {:ok, _} = Agents.update_harness(gemini, %{"command" => "g -p {prompt} [-c x={effort}]"})
    end
  end

  describe "deleting" do
    # Scenario 8
    test "a harness in use is refused, naming its agents; free once they are gone" do
      board = seeded_board()
      {gemini, pro} = gemini_pro(board)

      assert {:error, {:in_use, ["Gemini Pro"]}} = Agents.delete_harness(gemini)
      assert harness(board, "gemini-cli")

      assert {:ok, _} = Agents.delete_agent(pro)
      assert {:ok, _} = Agents.delete_harness(gemini)
      refute harness(board, "gemini-cli")
    end

    # Scenario 9
    test "the default agent and an agent named by a node are refused" do
      {:ok, board} = Relay.Boards.create_board(insert(:user), %{name: "Delete board"})

      assert {:error, :default} = Agents.delete_agent(agent(board, "Claude Opus"))

      spec_review = Enum.find(Relay.Flows.get_flow!(board, "code").nodes, &(&1.key == "spec_review"))
      assert spec_review.llm == "Claude Sonnet"

      assert {:error, {:in_use, pairs}} = Agents.delete_agent(agent(board, "Claude Sonnet"))
      assert {"code", "spec_review"} in pairs
    end

    # Scenario 11
    test "set_default_agent/2 moves the default so the old one is no longer protected as default" do
      board = seeded_board()
      sonnet = agent(board, "Claude Sonnet")

      assert {:ok, _board} = Agents.set_default_agent(board, sonnet)
      assert Agents.default_agent(board).name == "Claude Sonnet"

      assert {:ok, _} = Agents.delete_agent(agent(board, "Claude Opus"))
      assert {:error, :default} = Agents.delete_agent(agent(board, "Claude Sonnet"))
    end
  end

  # Scenario 10
  test "renaming an agent relabels every node naming it without bumping flow versions" do
    board = seeded_board()
    one = put_flow!(board, "one", [agent_node("a", "Claude Sonnet"), agent_node("b", nil)])
    two = put_flow!(board, "two", [agent_node("c", "Claude Sonnet"), agent_node("d", "Claude Sonnet")])

    assert {:ok, %Agent{name: "Sonnet 4"}} = Agents.update_agent(agent(board, "Claude Sonnet"), %{"name" => "Sonnet 4"})

    one = Repo.reload!(one)
    two = Repo.reload!(two)
    assert Enum.map(one.nodes, & &1.llm) == ["Sonnet 4", nil]
    assert Enum.map(two.nodes, & &1.llm) == ["Sonnet 4", "Sonnet 4"]
    assert one.version == 1 and two.version == 1

    assert Agents.node_usage(board) == %{"Sonnet 4" => [{"one", "a"}, {"two", "c"}, {"two", "d"}]}
    assert MapSet.member?(Agents.agent_names(board), "Sonnet 4")
    refute MapSet.member?(Agents.agent_names(board), "Claude Sonnet")
  end

  # Scenario 12
  test "create_harness/2 derives a unique key from the name; update never changes it" do
    board = seeded_board()

    assert {:ok, h} = Agents.create_harness(board, pi_attrs("pi"))
    assert h.key == "pi"
    assert h.models == ["qwen3-coder"]

    assert {:ok, h2} = Agents.create_harness(board, pi_attrs("pi!"))
    assert h2.key == "pi-2"

    assert {:error, cs} = Agents.create_harness(board, pi_attrs("pi"))
    assert "is already used on this board" in errors_on(cs).name

    assert {:ok, renamed} = Agents.update_harness(h, %{"name" => "Pi Agent"})
    assert renamed.key == "pi"
    assert renamed.name == "Pi Agent"
  end

  test "get_harness!/2 and get_agent!/2 are board-scoped" do
    board = seeded_board()
    other = seeded_board()

    assert Agents.get_harness!(board, harness(board, "codex").id).key == "codex"
    assert Agents.get_agent!(board, agent(board, "Claude Haiku").id).harness.key == "claude-code"

    assert_raise Ecto.NoResultsError, fn -> Agents.get_harness!(board, harness(other, "codex").id) end
    assert_raise Ecto.NoResultsError, fn -> Agents.get_agent!(board, agent(other, "Claude Haiku").id) end
  end

  # Task 2 · Scenario 13
  test "harnesses_digest/1 is stable and changes when a harness changes" do
    board = seeded_board()
    digest = Agents.harnesses_digest(board)

    assert digest == Agents.harnesses_digest(board)
    assert digest =~ ~r/\A[0-9a-f]{64}\z/

    {:ok, _} = Agents.update_harness(harness(board, "codex"), %{"command" => "codex exec --json {prompt}"})

    refute Agents.harnesses_digest(board) == digest
  end
end
