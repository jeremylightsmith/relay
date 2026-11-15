defmodule Hamaca.Runs.Cost do
  @moduledoc """
  The one parse of an outcome's reported `cost` and the one arithmetic that turns it into an
  execution's own spend (RE516) — pure functions, no Repo.

  A harness's `cost_path` names the **session's cumulative cost in USD**. Claude Code's
  `total_cost_usd` is the session's running total across `--resume` (verified on 2.1.325: a fresh
  session reported $0.00239, and the same session after `--resume` reported $0.00419), and a
  needs-input re-entry or a Steer-now restart resumes the same session. Storing the raw figure on
  every execution would double-count, so each execution stores `execution_delta/2`: the reported
  running total minus what the card's other executions on that session already recorded.

  `parse/1` never refuses: a bad value reads `nil` (unpriced), so an outcome is never lost to a
  4xx over its cost. Internal to the `Hamaca.Runs` boundary; not exported — the web layer goes
  through `Hamaca.Runs.parse_cost/1`.
  """

  @zero Decimal.new(0)

  @doc """
  A finite, non-negative cost from a JSON number or a wholly numeric string, else `nil` — missing,
  negative, non-numeric, partially numeric (`"1.5abc"`), NaN, infinite, booleans, lists and maps.
  Zero is a valid cost.
  """
  @spec parse(term()) :: Decimal.t() | nil
  def parse(value) when is_float(value), do: value |> Decimal.from_float() |> non_negative()
  def parse(value) when is_integer(value), do: value |> Decimal.new() |> non_negative()

  def parse(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} -> non_negative(decimal)
      _partial_or_error -> nil
    end
  end

  def parse(_value), do: nil

  @doc """
  An execution's own spend: `max(reported − prior, 0)`, where `prior` is what the card's other
  executions on the same session already recorded. An unreported cost stays `nil`.
  """
  @spec execution_delta(Decimal.t() | nil, Decimal.t()) :: Decimal.t() | nil
  def execution_delta(nil, _prior), do: nil
  def execution_delta(%Decimal{} = reported, %Decimal{} = prior), do: Decimal.max(Decimal.sub(reported, prior), @zero)

  defp non_negative(%Decimal{} = decimal) do
    cond do
      Decimal.nan?(decimal) or Decimal.inf?(decimal) -> nil
      Decimal.negative?(decimal) -> nil
      true -> decimal
    end
  end
end
