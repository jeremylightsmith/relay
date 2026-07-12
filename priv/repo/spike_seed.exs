# Seeds a small board for the dev-login user (dev@relay.local) so the Flutter
# embedding spike (flutter/) has a populated LiveView board to load at
# /board/spike. Run: mix run priv/repo/spike_seed.exs

import Ecto.Query

alias Relay.Accounts
alias Relay.Boards
alias Relay.Cards
alias Relay.Repo
alias Schemas.Board

user = Accounts.ensure_dev_user!()
actor = {:user, user.id}

Repo.delete_all(from(b in Board, where: b.owner_id == ^user.id and b.slug == "spike"))

{:ok, board} = Boards.create_board(user, %{name: "Spike Board", slug: "spike", key: "SPIKE"})
stages = Map.new(Boards.list_stages(board), &{&1.name, &1})

place = fn stage_name, title, status ->
  stage = Map.fetch!(stages, stage_name)
  {:ok, card} = Cards.create_card(stage, %{title: title}, actor)
  if status, do: Cards.set_status(card, %{status: status}, actor)
end

# Default pipeline: Backlog · Next up · Spec · Plan · Code · Review · Deploy · Done
place.("Backlog", "Bulk CSV export for reports", nil)
place.("Backlog", "Dark mode for the dashboard", nil)
place.("Next up", "Add SSO via Google Workspace", nil)
place.("Spec", "Team billing & seats", :working)
place.("Code", "Org-level RBAC", :working)
place.("Code", "Fix the N+1 on the board query", :working)
place.("Code", "Multi-region data residency", :needs_input)
place.("Review", "Rate-limiter middleware", :in_review)
place.("Deploy", "Roll out card archiving", :working)
place.("Done", "OAuth login", nil)

IO.puts("Seeded 'spike' board for #{user.email}: #{length(Cards.list_cards(board))} cards")
