defmodule HamacaWeb.ReportFlow do
  @moduledoc """
  The report flow's socket logic (RE510), shared by `HamacaWeb.PublicBoardLive` (ideas, `:card`)
  and the card drawer in `HamacaWeb.BoardLive` (comments, `:comment`). Both LiveViews handle the
  same events (`"open_report"`, `"change_report"`, `"submit_report"`, `"close_report"`,
  `"show_reported"`) by delegating here, and render `report_modal/1` and
  `reported_placeholder/1` from the assigns this module owns:

    * `report_kind` — the one kind this LiveView reports
    * `report_target` — `%{kind, id, quote}` while the modal is open, else `nil`
    * `report_step` — `:form` or `:sent`
    * `report_form` — the `report` form
    * `reported_ids` — what the viewer reported (`Hamaca.Moderation.hidden_for_reporter_ids/2`),
      collapsed for them
    * `shown_reported_ids` — reported items the viewer chose to "Show anyway"; per LiveView
      session only, never stored
    * `report_sla_hours` — `Hamaca.Moderation.response_sla_hours/0`, for the confirmation

  The caller authorizes the target (finds it among what it rendered) before `open/2`;
  `Hamaca.Moderation.report/3` re-checks on submit.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Hamaca.Moderation
  alias Phoenix.LiveView.Socket

  @kinds [:card, :comment]

  @type target :: %{kind: :card | :comment, id: integer(), quote: String.t()}

  @doc "Assigns the flow's initial state for a LiveView that reports `kind`."
  @spec init(Socket.t(), :card | :comment) :: Socket.t()
  def init(%Socket{} = socket, kind) when kind in @kinds do
    socket
    |> assign(:report_kind, kind)
    |> assign(:report_sla_hours, Moderation.response_sla_hours())
    |> assign(:reported_ids, Moderation.hidden_for_reporter_ids(current_user(socket), kind))
    |> assign(:shown_reported_ids, MapSet.new())
    |> close()
  end

  @doc """
  Maps a `phx-value-kind` string to its atom by matching the known kinds (never
  `String.to_atom/1`); anything else is `nil`.
  """
  @spec kind_param(term()) :: :card | :comment | nil
  def kind_param(value) when is_binary(value), do: Enum.find(@kinds, &(Atom.to_string(&1) == value))
  def kind_param(_value), do: nil

  @doc "Opens the modal on the form step for an already-authorized `target`."
  @spec open(Socket.t(), target()) :: Socket.t()
  def open(%Socket{} = socket, %{kind: kind, id: id, quote: quote} = target)
      when kind in @kinds and is_integer(id) and is_binary(quote) do
    socket
    |> assign(:report_target, target)
    |> assign(:report_step, :form)
    |> assign(:report_form, blank_form())
  end

  @doc "Re-assigns the form from the `\"report\"` params, so the Send button tracks the reason."
  @spec change(Socket.t(), map()) :: Socket.t()
  def change(%Socket{} = socket, params) do
    assign(socket, :report_form, to_form(form_params(params), as: :report))
  end

  @doc """
  Records `user`'s report of the open target. A fresh or repeat report moves to the `:sent`
  step and collapses the item for the viewer; an invalid one keeps the form with its errors; a
  refused one closes the modal with an error flash.
  """
  @spec submit(Socket.t(), Schemas.User.t(), map()) :: {:ok, Socket.t()} | {:error, Socket.t()}
  def submit(%Socket{assigns: %{report_target: %{kind: kind, id: id}}} = socket, user, params) do
    case Moderation.report(user, {kind, id}, form_params(params)) do
      {:ok, _report} ->
        {:ok,
         socket
         |> assign(:report_step, :sent)
         |> assign(:reported_ids, MapSet.put(socket.assigns.reported_ids, id))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, assign(socket, :report_form, to_form(changeset, as: :report, action: :validate))}

      {:error, reason} when reason in [:own_content, :not_reportable, :suspended] ->
        {:error, socket |> close() |> put_flash(:error, "That can't be reported.")}
    end
  end

  def submit(%Socket{} = socket, _user, _params), do: {:error, socket}

  @doc "Closes the modal and resets it to an empty form."
  @spec close(Socket.t()) :: Socket.t()
  def close(%Socket{} = socket) do
    socket
    |> assign(:report_target, nil)
    |> assign(:report_step, :form)
    |> assign(:report_form, blank_form())
  end

  @doc "Reveals a reported item for the rest of this LiveView session (never stored)."
  @spec show_anyway(Socket.t(), integer()) :: Socket.t()
  def show_anyway(%Socket{} = socket, id) when is_integer(id) do
    assign(socket, :shown_reported_ids, MapSet.put(socket.assigns.shown_reported_ids, id))
  end

  @doc """
  True when the viewer `viewer_id` may report `comment` from the card drawer: another human's
  comment that isn't hidden for everyone. Agent comments and the viewer's own get no Report. The
  ONE rule — the drawer's ⋯ menu and BoardLive's `"open_report"` authorization both call it.
  `comment.user` must be preloaded.
  """
  @spec reportable_comment?(Schemas.Comment.t(), integer() | nil) :: boolean()
  def reportable_comment?(%Schemas.Comment{actor_type: :user, user_id: author_id} = comment, viewer_id)
      when is_integer(author_id) do
    author_id != viewer_id and not Moderation.hidden_for_everyone?(comment)
  end

  def reportable_comment?(%Schemas.Comment{}, _viewer_id), do: false

  @doc "True when the viewer reported item `id` and hasn't chosen to show it."
  @spec collapsed?(map(), integer()) :: boolean()
  def collapsed?(%{reported_ids: reported, shown_reported_ids: shown}, id) do
    MapSet.member?(reported, id) and not MapSet.member?(shown, id)
  end

  defp blank_form, do: to_form(%{"reason" => "", "note" => ""}, as: :report)

  defp form_params(params) when is_map(params) do
    %{"reason" => to_string(params["reason"] || ""), "note" => to_string(params["note"] || "")}
  end

  defp current_user(%Socket{assigns: %{current_scope: %{user: user}}}), do: user
  defp current_user(_socket), do: nil
end
