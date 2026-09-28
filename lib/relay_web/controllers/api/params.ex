defmodule RelayWeb.Api.Params do
  @moduledoc "Request-parameter parsing shared by the API controllers."

  @doc """
  A path id as an integer. An id that doesn't cast can't match any row, so callers treat
  `:error` as not-found rather than letting Ecto raise a CastError.
  """
  def parse_int_id(id) when is_integer(id), do: {:ok, id}

  def parse_int_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end
end
