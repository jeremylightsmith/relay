defmodule Hamaca.StoreScreenshotSeedsTest do
  @moduledoc """
  RE479 — the App Store screenshots are captured against the "Forkful" board this script seeds, so
  the script must actually build every state a shot shows: the Review card with its two recipe-page
  mockups, a structured question for the Answer shot, a Needs-you inbox, and agents working in
  several stages for the Board shot. Evaluating the script is the only honest check.
  """
  use Hamaca.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Hamaca.Accounts
  alias Hamaca.Attachments
  alias Hamaca.Cards
  alias Hamaca.Repo
  alias Schemas.Board
  alias Schemas.Card

  @script "priv/repo/store_screenshot_seeds.exs"

  setup do
    capture_io(fn -> Code.eval_file(@script) end)
    dev_user = Accounts.ensure_dev_user!()
    board = Repo.get_by!(Board, owner_id: dev_user.id, slug: "forkful")
    %{board: Repo.preload(board, :stages), dev_user: dev_user}
  end

  defp seeded_card(board, title) do
    card = Card |> Repo.get_by(board_id: board.id, title: title) |> Repo.preload(:stage)
    assert card, "the seed script should create a #{inspect(title)} card"
    card
  end

  test "running the script twice leaves exactly one Forkful board", %{dev_user: dev_user} do
    capture_io(fn -> Code.eval_file(@script) end)

    boards = Repo.all(from b in Board, where: b.owner_id == ^dev_user.id and b.slug == "forkful")

    assert [%Board{name: "Forkful"}] = boards
  end

  test "the recipe-page card waits in Design's Review lane with two captioned mockups", %{board: board} do
    card = seeded_card(board, "Redesign the recipe page")
    design = Enum.find(board.stages, &(&1.name == "Design" and is_nil(&1.parent_id)))

    assert card.stage.parent_id == design.id
    assert card.stage.type == :review
    assert card.status == :in_review
    assert card.ai_result["summary"] == "Two layouts for the recipe page. A leads with the photo."

    captions = Enum.map(card.mockups, & &1["caption"])
    assert length(captions) == 2
    assert hd(captions) == "A — photo header, two columns"
    assert Enum.all?(card.mockups, &String.starts_with?(&1["url"], "/attachments/"))
  end

  test "the dev user's Needs-you feed carries the review card and a structured question",
       %{board: board, dev_user: dev_user} do
    rows = dev_user |> Cards.needs_you_feed() |> Enum.filter(&(&1.card.board_id == board.id))

    assert length(rows) >= 3
    assert "Redesign the recipe page" in Enum.map(rows, & &1.card.title)

    assert Enum.any?(rows, fn row ->
             is_list(row.questions) and row.questions != [] and
               Enum.all?(row.questions, &(is_map(&1) and is_binary(&1["prompt"]) and length(&1["options"]) == 2))
           end)
  end

  test "agents are working in at least three different main stages", %{board: board} do
    working_stage_ids =
      Repo.all(
        from c in Card,
          join: s in assoc(c, :stage),
          where: c.board_id == ^board.id and c.status == :working,
          select: coalesce(s.parent_id, s.id)
      )

    assert working_stage_ids |> Enum.uniq() |> length() >= 3
  end

  # The Board shot is a board on a good day: no first-run setup checklist covering the lanes, and
  # no "no runner is connected" banner over the queued work while a capture runs.
  test "the board reads as long set up, with no guided-setup checklist", %{board: board} do
    assert Hamaca.Setup.checklist(board) == nil
  end

  test "a runner stays connected for the length of a capture", %{board: board} do
    runner = Repo.get_by!(Schemas.Runner, board_id: board.id)
    half_an_hour_on = DateTime.add(DateTime.utc_now(), 30 * 60, :second)

    assert Hamaca.Runs.runner_freshness(runner, half_an_hour_on) == :fresh
    assert runner.version >= Hamaca.Runs.min_runner_version()
  end

  test "the first mockup is a self-contained recipe page with the photo inlined and no credit", %{board: board} do
    [first | _] = seeded_card(board, "Redesign the recipe page").mockups
    {:ok, id} = Schemas.Attachment.id_from_path(first["url"])
    {:ok, html} = id |> Attachments.get_attachment() |> Attachments.fetch_bytes()

    assert html =~ "Weeknight lemon pasta"
    assert html =~ ~r/<img[^>]+src="data:image\/jpeg;base64,/
    refute html =~ ~r/<img[^>]+src="(?!data:)/
    refute html =~ "lemon-spaghetti"
    refute html =~ "CC BY"
  end
end
