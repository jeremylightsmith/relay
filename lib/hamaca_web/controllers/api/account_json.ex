defmodule HamacaWeb.Api.AccountJSON do
  @moduledoc """
  The account-deletion preview (RE509, `GET /api/all/account/deletion`): every fact comes from
  `Hamaca.Accounts.deletion_preview/1`. A candidate's `member_since` goes out as an ISO 8601
  date string.
  """

  def deletion(%{preview: preview}) do
    %{
      data: %{
        shared_boards: Enum.map(preview.shared_boards, &shared_board/1),
        solo_boards: Enum.map(preview.solo_boards, &%{slug: &1.slug, name: &1.name}),
        plan_ends: preview.plan_ends,
        runners: preview.runners,
        apple_reauth_required: preview.apple_reauth_required
      }
    }
  end

  defp shared_board(board) do
    %{
      slug: board.slug,
      name: board.name,
      member_count: board.member_count,
      candidates: Enum.map(board.candidates, &candidate/1)
    }
  end

  defp candidate(candidate) do
    %{
      user_id: candidate.user_id,
      name: candidate.name,
      avatar_url: candidate.avatar_url,
      member_since: Date.to_iso8601(candidate.member_since)
    }
  end
end
