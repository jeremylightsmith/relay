defmodule RelayWeb.RunStatusTest do
  use ExUnit.Case, async: true

  alias RelayWeb.RunStatus

  test "descriptor covers every Schemas.Run status with label/token/icon" do
    for status <- Ecto.Enum.values(Schemas.Run, :status) do
      d = RunStatus.descriptor(status)
      assert d.label != ""
      assert String.starts_with?(d.token, "--color-")
      assert d.icon != ""
    end
  end

  test "labels assert no cause the status doesn't guarantee" do
    labels = for s <- Ecto.Enum.values(Schemas.Run, :status), do: RunStatus.descriptor(s).label
    joined = Enum.join(labels, " ")
    refute joined =~ ~r/merged/i
    refute joined =~ ~r/claimed/i
  end

  test "canonical values" do
    assert RunStatus.descriptor(:done) == %{label: "Completed", token: "--color-success", icon: "✓"}
    assert RunStatus.descriptor(:failed) == %{label: "Run failed", token: "--color-error", icon: "!"}
    assert RunStatus.descriptor(:cancelled) == %{label: "Cancelled", token: "--color-neutral", icon: "⊘"}
    assert RunStatus.descriptor(:parked) == %{label: "Parked", token: "--color-warning", icon: "?"}
    assert RunStatus.descriptor(:running) == %{label: "Running", token: "--color-secondary", icon: "●"}
  end
end
