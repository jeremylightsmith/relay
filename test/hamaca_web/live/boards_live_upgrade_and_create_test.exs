defmodule HamacaWeb.BoardsLiveUpgradeAndCreateTest do
  @moduledoc """
  RE472: at the Free limit the New-board picker's **Upgrade and create →** validates like Create,
  carries the pending board through the setup Checkout in a signed token (or upgrades in place on
  a $0 charge), and the return creates and opens the board — once.
  """
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hamaca.Billing
  alias Hamaca.Billing.Standing
  alias Hamaca.Boards
  alias Hamaca.Repo
  alias HamacaWeb.PendingBoard
  alias HamacaWeb.TemplatePickerComponents
  alias Schemas.Board

  @identity %{"template" => "design-led", "name" => "Acme Checkout", "key" => "AC"}

  setup :register_and_log_in_user

  setup %{user: user} do
    Process.put(:billing_enabled, true)
    %{default_board: Boards.get_or_create_default_board(user), today: Date.utc_today()}
  end

  defp open_picker(conn) do
    {:ok, view, _html} = live(conn, ~p"/boards")
    view |> element("#top-bar-new-board") |> render_click()
    view
  end

  defp fill(view, identity \\ @identity) do
    view |> element("#template-picker-form") |> render_change(identity)
    view
  end

  defp click_upgrade_create(view), do: view |> element("#template-picker-upgrade-create") |> render_click()

  # Clicks Upgrade and create → on scenario 5's filled picker and answers the dev Checkout's
  # `succeed` and `decline` return paths.
  defp checkout_paths(conn, identity \\ @identity) do
    assert {:error, {:redirect, %{to: url}}} = conn |> open_picker() |> fill(identity) |> click_upgrade_create()
    assert url =~ "/dev/billing-checkout"

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    %{succeed: query["succeed"], decline: query["decline"]}
  end

  # A flash pushed from the connected LiveView travels signed in the redirect; the page it lands
  # on shows it.
  defp flash_info(redirect, conn) do
    {:ok, board_view, _html} = follow_redirect(redirect, conn)
    board_view |> element("#flash-info") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()
  end

  defp boards_named(user, name), do: user |> Boards.list_boards() |> Enum.filter(&(&1.name == name))

  defp value(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.attribute("value") |> hd()
  end

  test "5. Upgrade and create goes to Checkout carrying a pending token, creating nothing", %{conn: conn, user: user} do
    %{succeed: succeed, decline: decline} = checkout_paths(conn)

    assert succeed =~ ~r"^/boards\?pending=[^&]+&setup=local_4242_#{user.id}$"
    assert decline =~ ~r"^/boards\?pending=[^&]+&setup=local_0341_#{user.id}$"
    assert length(Boards.list_boards(user)) == 1
  end

  # RE480 scenario 7
  test "Upgrade and create's checkout return URL follows the configured host, not the request's", %{conn: conn} do
    assert {:error, {:redirect, %{to: url}}} =
             %{conn | host: "relayboard.fly.dev"} |> open_picker() |> fill() |> click_upgrade_create()

    assert String.starts_with?(url, HamacaWeb.Endpoint.url() <> "/dev/billing-checkout?")
    refute url =~ "relayboard.fly.dev"
  end

  test "6. the successful return creates the board, opens it and upgrades the owner", %{
    conn: conn,
    user: user,
    today: today
  } do
    %{succeed: succeed} = checkout_paths(conn)

    assert {:error, {:live_redirect, %{to: "/board/" <> slug}}} = result = live(conn, succeed)
    assert flash_info(result, conn) == "Upgraded. Acme Checkout is ready."

    assert length(Boards.list_boards(user)) == 2
    board = Repo.get_by!(Board, slug: slug)
    assert board.name == "Acme Checkout"
    assert board.key == "AC"

    main_stages = board |> Boards.list_stages() |> Enum.filter(&is_nil(&1.parent_id)) |> Enum.map(& &1.name)
    assert main_stages == Enum.map(Boards.Templates.get("design-led").stages, & &1.name)

    assert Standing.kind(Billing.summary(user, today).standing) == :active
  end

  test "7. a replayed return opens the board it already created", %{conn: conn, user: user} do
    %{succeed: succeed} = checkout_paths(conn)
    assert {:error, {:live_redirect, %{to: "/board/" <> slug}}} = live(conn, succeed)

    assert {:error, {:live_redirect, %{to: "/board/" <> ^slug} = redirect}} = live(conn, succeed)
    refute Map.has_key?(redirect, :flash)
    assert length(boards_named(user, "Acme Checkout")) == 1
  end

  test "7. a replayed return finds the board when the changeset normalized the typed name and key", %{
    conn: conn,
    user: user
  } do
    %{succeed: succeed} = checkout_paths(conn, %{@identity | "name" => "  Acme Checkout ", "key" => "ac"})
    assert {:error, {:live_redirect, %{to: "/board/" <> slug}}} = live(conn, succeed)

    assert {:error, {:live_redirect, %{to: "/board/" <> ^slug}}} = live(conn, succeed)
    assert [%Board{key: "AC"}] = boards_named(user, "Acme Checkout")
  end

  test "8. a declined return reopens the picker prefilled and creates nothing", %{conn: conn, user: user} do
    %{decline: decline} = checkout_paths(conn)

    {:ok, view, _html} = live(conn, decline)

    assert render(view) =~ "That card was declined."
    assert has_element?(view, "#template-picker")
    assert value(view, "#template-picker-name") == "Acme Checkout"
    assert value(view, "#template-picker-key") == "AC"
    assert has_element?(view, "#template-radio-design-led[checked]")
    assert view |> element("#template-picker-upgrade-name") |> render() =~ ">Acme Checkout</b>"
    assert length(Boards.list_boards(user)) == 1
  end

  test "9. a declined copy return reopens the picker on the copy option and its source", %{
    conn: conn,
    user: user,
    default_board: default_board
  } do
    token = PendingBoard.sign(user, %{name: "Copy Two", key: "CT", copy_from: default_board.slug})

    {:ok, view, _html} = live(conn, "/boards?pending=#{token}&setup=local_0341_#{user.id}")

    assert has_element?(view, "#template-picker")
    assert has_element?(view, "#template-radio-copy[checked]")
    assert has_element?(view, "#copy-source-radio-#{default_board.slug}[checked]")
    assert value(view, "#template-picker-name") == "Copy Two"
    assert boards_named(user, "Copy Two") == []
    assert length(Boards.list_boards(user)) == 1
  end

  test "a return whose template is gone reopens the picker with Create's flash, creating nothing", %{
    conn: conn,
    user: user
  } do
    token = PendingBoard.sign(user, %{name: "Acme Checkout", key: "AC", template: "no-such-template"})

    {:ok, view, html} = live(conn, "/boards?pending=#{token}&setup=local_4242_#{user.id}")

    assert html =~ "That template no longer exists. Pick another."
    assert has_element?(view, "#template-picker")
    assert value(view, "#template-picker-name") == "Acme Checkout"
    assert boards_named(user, "Acme Checkout") == []
  end

  test "10. a tampered token creates nothing and opens a blank picker", %{conn: conn, user: user} do
    token = PendingBoard.sign(user, %{name: "Acme Checkout", key: "AC", template: "design-led"})
    bad = HamacaWeb.TokenHelpers.tamper(token)

    {:ok, view, _html} = live(conn, "/boards?pending=#{bad}&setup=local_4242_#{user.id}")

    assert render(view) =~ "Card saved and charged. Your boards are editable."
    assert has_element?(view, "#template-picker")
    assert value(view, "#template-picker-name") == ""
    assert boards_named(user, "Acme Checkout") == []
  end

  test "11. an expired token creates nothing", %{conn: conn, user: user} do
    signed_at = System.system_time(:second) - PendingBoard.max_age() - 60
    token = PendingBoard.sign(user, %{name: "Acme Checkout", key: "AC", template: "design-led"}, signed_at: signed_at)

    # No redirect: the view stays on /boards.
    {:ok, _view, _html} = live(conn, "/boards?pending=#{token}&setup=local_4242_#{user.id}")

    assert boards_named(user, "Acme Checkout") == []
    assert length(Boards.list_boards(user)) == 1
  end

  test "12. another user's token creates nothing for either user", %{conn: conn, user: user} do
    other = insert(:user)
    token = PendingBoard.sign(other, %{name: "Theirs", key: "TH", template: "design-led"})

    {:ok, _view, _html} = live(conn, "/boards?pending=#{token}&setup=local_4242_#{user.id}")

    assert boards_named(user, "Theirs") == []
    assert boards_named(other, "Theirs") == []
  end

  test "13. a $0 next charge upgrades in place and creates without Checkout", %{conn: conn, user: user, today: today} do
    insert(:promo_code, code: "FRIENDS", percent_off: 100, months: 2)
    {:ok, _account} = Billing.redeem_code(user, "FRIENDS", today)

    assert {:error, {:live_redirect, %{to: "/board/" <> _slug}}} =
             result = conn |> open_picker() |> fill() |> click_upgrade_create()

    assert flash_info(result, conn) == "Upgraded. Acme Checkout is ready."

    assert length(Boards.list_boards(user)) == 2
  end

  test "14. a key Create would reject keeps the picker open with the error inline", %{conn: conn, user: user} do
    # Aimed at the key, so it isn't re-derived from the name.
    view = conn |> open_picker() |> fill(Map.merge(@identity, %{"key" => "A", "_target" => ["key"]}))

    html = click_upgrade_create(view)

    assert is_binary(html)
    assert has_element?(view, "#template-picker")
    assert has_element?(view, "#template-picker-key-hint.text-error", "must be exactly 2 letters")
    assert length(Boards.list_boards(user)) == 1
  end

  test "14. a blank name shows the name error Create shows", %{conn: conn, user: user} do
    view = conn |> open_picker() |> fill(Map.merge(@identity, %{"name" => "", "_target" => ["key"]}))

    # A blank name disables the button, so the click is sent as the event it emits.
    html = render_click(view, "upgrade_and_create", %{})

    assert is_binary(html)
    assert has_element?(view, "#template-picker")
    # The message Create shows for a blank name (`boards_live_template_picker_test.exs` 16b):
    # `Schemas.Board.changeset/2` casts with `empty_values: []`, so it is the length rule's.
    assert has_element?(view, "#template-picker-name-hint.text-error", "should be at least 1 character(s)")
    assert length(Boards.list_boards(user)) == 1
  end

  test "15. an unknown template flashes and creates nothing", %{conn: conn, user: user} do
    view = open_picker(conn)

    html = render_click(view, "upgrade_and_create", %{"template" => "no-such-template", "name" => "X", "key" => "XX"})

    assert html =~ "That template no longer exists. Pick another."
    assert has_element?(view, "#template-picker")
    assert length(Boards.list_boards(user)) == 1
  end

  test "16. a cancelled Checkout reopens the picker prefilled, without a flash", %{conn: conn, user: user} do
    token = PendingBoard.sign(user, %{name: "Acme Checkout", key: "AC", template: "design-led"})

    {:ok, view, _html} = live(conn, "/boards?pending=#{token}")

    assert has_element?(view, "#template-picker")
    assert value(view, "#template-picker-name") == "Acme Checkout"
    assert value(view, "#template-picker-key") == "AC"
    refute has_element?(view, "#flash-info")
    refute has_element?(view, "#flash-error")
    assert length(Boards.list_boards(user)) == 1
  end

  test "17. embedded, there is no Upgrade and create and the event refuses", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/boards?embed=1")
    view |> element("#new-board-button") |> render_click()

    assert has_element?(view, "#template-picker-upgrade")
    refute has_element?(view, "#template-picker-upgrade-create")

    html = render_click(view, "upgrade_and_create", %{"template" => "design-led", "name" => "X", "key" => "XX"})

    assert html =~ "Free includes one board. Upgrade for unlimited boards."
    assert length(Boards.list_boards(user)) == 1
  end

  test "the copy option with no source refuses like Create", %{conn: conn} do
    view = open_picker(conn)

    html =
      render_click(view, "upgrade_and_create", %{
        "template" => TemplatePickerComponents.copy_option(),
        "copy_from" => "no-such-board",
        "name" => "X",
        "key" => "XX"
      })

    assert html =~ "That board isn&#39;t available to copy. Pick another."
  end
end
