defmodule Hamaca.Moderation.Notifier do
  @moduledoc """
  The operator's email for every new content report (RE510), sent to every
  `Schemas.Scope.superadmin_emails/0` address through the leaf `Hamaca.Mailer`.

  `deliver/1` and `dispatch/1` mirror `Hamaca.Billing.Notifier`'s: mail goes out only when
  `:mail_enabled` is true (otherwise a log line), off the caller's process under
  `Hamaca.Moderation.TaskSupervisor` (inline when the config's `:async` is false, as in test), and
  nothing here ever raises into the reporter's request.
  """

  import Swoosh.Email

  alias Hamaca.Brand
  alias Schemas.ContentReport
  alias Schemas.User

  require Logger

  @reports_path "/admin/reports"

  @doc "The email telling the operator about `report`, whose item's open row is `row`."
  @spec new_report_email(ContentReport.t(), Hamaca.Moderation.row()) :: Swoosh.Email.t()
  def new_report_email(%ContentReport{} = report, row) do
    url = Hamaca.Config.get(:app_url) <> @reports_path
    reporter = Enum.find(row.reporters, &(&1.id == report.reporter_id))

    lines =
      [
        "#{Brand.name()} has a new report: #{ContentReport.reason_label(report.reason)}.",
        "Board: #{row.board.name} · #{row.card_ref}",
        "Reported #{row.kind}: “#{row.excerpt}”",
        "Posted by: #{person(row.poster)}",
        "Reported by: #{person(reporter)}"
      ] ++ if(report.note, do: ["Note: #{report.note}"], else: [])

    new()
    |> to(Enum.map(Schemas.Scope.superadmin_emails(), &{"", &1}))
    |> from(sender(Application.get_env(:hamaca, :mail_from)))
    |> subject("New report: #{ContentReport.reason_label(report.reason)} on #{row.board.name}")
    |> text_body(Enum.join(lines, "\n") <> "\n\nReview it: #{url}\n")
    |> html_body(
      Enum.map_join(lines, "\n", &"<p>#{escape(&1)}</p>") <> ~s(\n<p><a href="#{escape(url)}">Review it</a></p>\n)
    )
  end

  defp person(nil), do: "unknown"
  defp person(%User{name: name, email: email}) when name in [nil, ""], do: email
  defp person(%User{name: name, email: email}), do: "#{name} · #{email}"

  # A private copy of `Hamaca.Billing.Notifier.sender/1`'s parse — Moderation must not depend on
  # Billing. `"Name <addr>"` or a bare address → Swoosh's `{name, address}`.
  defp sender(mail_from) when is_binary(mail_from) do
    case Regex.run(~r/^\s*(.*?)\s*<([^<>]+)>\s*$/, mail_from) do
      [_, name, address] -> {String.trim(name, "\""), String.trim(address)}
      nil -> {"", String.trim(mail_from)}
    end
  end

  @doc """
  Sends `email` through `Hamaca.Mailer` when `:mail_enabled` is `true`; otherwise logs that it
  was not sent. Always `:ok` — a failed or raising delivery is logged, never raised.
  """
  @spec deliver(Swoosh.Email.t()) :: :ok
  def deliver(%Swoosh.Email{} = email) do
    if Hamaca.Config.get(:mail_enabled, false) == true do
      send_now(email)
    else
      Logger.info(
        ~s(Moderation.Notifier: no mail provider configured; not sending "#{email.subject}" to #{recipient(email)})
      )
    end

    :ok
  end

  @doc """
  Runs `fun` under `Hamaca.Moderation.TaskSupervisor` (inline when the notifier config's `:async`
  is false, as in test). Never raises or exits into the caller.
  """
  @spec dispatch((-> any())) :: :ok
  def dispatch(fun) when is_function(fun, 0) do
    safely(fn -> dispatch_now(config(), fun) end)
  end

  # Read once at the boundary (ADR 0009 rule 1), like `Hamaca.Billing.Notifier`'s.
  defp config do
    env = Application.get_env(:hamaca, __MODULE__, [])

    %{
      async: Keyword.get(env, :async, true),
      task_supervisor: Keyword.get(env, :task_supervisor, Hamaca.Moderation.TaskSupervisor)
    }
  end

  # `start_child` is a `GenServer.call` to the named supervisor, which *exits* if that process is
  # unavailable — so the whole decision runs under `safely/1`.
  defp dispatch_now(%{async: true} = config, fun) do
    Task.Supervisor.start_child(config.task_supervisor, fn -> safely(fun) end)
  end

  defp dispatch_now(%{async: false}, fun), do: fun.()

  defp safely(fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error("Moderation.Notifier: dispatch failed: #{Exception.format(:error, error, __STACKTRACE__)}")
      :ok
  catch
    kind, reason ->
      Logger.error("Moderation.Notifier: dispatch #{kind}: #{inspect(reason)}")
      :ok
  end

  defp send_now(email) do
    case Hamaca.Mailer.deliver(email) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          ~s(Moderation.Notifier: sending "#{email.subject}" to #{recipient(email)} failed: #{inspect(reason)})
        )
    end
  rescue
    error ->
      Logger.error("Moderation.Notifier: delivery raised: #{Exception.format(:error, error, __STACKTRACE__)}")
  catch
    kind, reason ->
      Logger.error("Moderation.Notifier: delivery #{kind}: #{inspect(reason)}")
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp recipient(%Swoosh.Email{to: [{_name, address} | _]}), do: address
  defp recipient(%Swoosh.Email{}), do: "nobody"
end
