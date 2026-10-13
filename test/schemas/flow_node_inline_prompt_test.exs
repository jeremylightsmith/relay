defmodule Schemas.FlowNodeInlinePromptTest do
  @moduledoc """
  RE444: "inline prompt" is one predicate — an agent node with no subagent runs its `run` text
  as written. The flow editor's "inline · no skill" tag and the example board's node panel both
  read it.
  """
  use ExUnit.Case, async: true

  alias Schemas.Flow.Node

  describe "inline_prompt?/1" do
    test "an agent node with no subagent is an inline prompt" do
      assert Node.inline_prompt?(%{type: :agent, agent: nil})
      assert Node.inline_prompt?(%{type: :agent, agent: ""})
    end

    test "an agent node naming a subagent is not" do
      refute Node.inline_prompt?(%{type: :agent, agent: "plan-implementer"})
    end

    test "a non-agent node is never an inline prompt" do
      refute Node.inline_prompt?(%{type: :shell, agent: nil})
      refute Node.inline_prompt?(%Node{type: :fan_out})
    end
  end
end
