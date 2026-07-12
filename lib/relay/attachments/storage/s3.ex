defmodule Relay.Attachments.Storage.S3 do
  @moduledoc """
  S3-compatible storage adapter for attachments (RLY-13) — prod, pointed at
  Tigris via `ex_aws`. **Not exercised by the test suite** (tests use the
  Local adapter); the bucket + `AWS_*` config come from Fly-provisioned env
  read in `config/runtime.exs`. `ex_aws` is the deliberate exception to the
  project's "prefer Req" rule — S3 SigV4 signing is what it exists for.
  """

  @behaviour Relay.Attachments.Storage

  @impl true
  def put(key, bytes, content_type) do
    bucket()
    |> ExAws.S3.put_object(key, bytes, content_type: content_type)
    |> ExAws.request()
    |> case do
      {:ok, _resp} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key) do
    bucket()
    |> ExAws.S3.get_object(key)
    |> ExAws.request()
    |> case do
      {:ok, %{body: bytes}} -> {:ok, bytes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bucket, do: System.fetch_env!("BUCKET_NAME")
end
