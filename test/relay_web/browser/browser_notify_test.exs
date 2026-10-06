defmodule RelayWeb.Browser.BrowserNotifyTest do
  @moduledoc """
  Real-browser (Playwright) tests for RE399's `BrowserNotify` hook: the permission rows of the
  avatar menu, the focused-tab toast + horn, the background-tab OS notification + horn + "(n)"
  title + favicon dot, clearing on focus, the Sound switch, and "Open card" / notification click
  landing on the card drawer across boards.

  Everything the hook does is client-side, so a LiveView test cannot see it. The browser APIs it
  depends on are stubbed per test via `Frame.evaluate` (after load, before the event): focus
  (`document.hasFocus` — headless focus is not reliable), the horn (`HTMLMediaElement#play`
  records into `window.__horns`), and `window.Notification` (records into `window.__notifs`).
  Status changes are triggered from the test process with `Cards.set_status/3` as `:agent`
  (push dispatches inline in `:test`).

  The "several tabs fire only once" guarantee (the Web Lock) cannot be observed from one page;
  `RelayWeb.BrowserNotifyHookTest` pins it at the source.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Push

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 1440, height: 900}]

  setup do
    user = Accounts.ensure_dev_user!()
    n = System.unique_integer([:positive])

    x = Boards.get_or_create_default_board(user)
    {:ok, y} = Boards.create_board(user, %{name: "Y #{n}", slug: "y-notify-#{n}"})

    cx = card!(x, "Notify X card #{n}")
    cx2 = card!(x, "Notify X second card #{n}")
    cy = card!(y, "Notify Y card #{n}")

    %{user: user, x: x, y: y, cx: cx, cx2: cx2, cy: cy}
  end

  defp card!(board, title) do
    stage = Enum.find(board.stages, &(&1.name == "Code")) || hd(board.stages)
    {:ok, card} = Cards.create_card(stage, %{title: title})
    card
  end

  defp ref(board, card), do: Cards.ref(board, card)

  defp change(card, status, actor \\ :agent) do
    {:ok, _card} = Cards.set_status(Relay.Repo.get!(Schemas.Card, card.id), %{status: status}, actor)
    :ok
  end

  # ── page + stubs ────────────────────────────────────────────────────────────────────────────

  defp open_board(conn, board) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}")
    |> assert_has("body .phx-connected")
    |> assert_has("html[data-notify-permission]")
  end

  @horn_stub ~S"""
  HTMLMediaElement.prototype.play = function() { (window.__horns ||= []).push(this.src); return Promise.resolve() }
  """

  defp stub(conn, opts) do
    focus = Keyword.fetch!(opts, :focus)

    notification =
      case Keyword.get(opts, :permission) do
        nil -> ""
        permission -> notification_stub(permission)
      end

    js!(conn, "document.hasFocus = () => #{focus}; #{@horn_stub}; #{notification}; true")
  end

  defp notification_stub(permission) do
    String.replace(
      ~S"""
      window.Notification = class {
        static permission = "PERMISSION";
        static requestPermission() {
          window.__permReqs = (window.__permReqs || 0) + 1;
          window.Notification.permission = "granted";
          return Promise.resolve("granted");
        }
        constructor(title, opts) {
          (window.__notifs ||= []).push({title, body: opts.body, tag: opts.tag, icon: opts.icon, instance: this});
        }
        close() {}
      };
      """,
      "PERMISSION",
      permission
    )
  end

  defp js!(conn, js) do
    unwrap(conn, fn %{frame_id: frame_id} -> eval!(frame_id, js) end)
  end

  defp eval!(frame_id, js) do
    {:ok, value} = Frame.evaluate(frame_id, expression: "(() => { #{js} })()", timeout: 2_000)
    value
  end

  defp value(conn, js) do
    {:ok, value} = Frame.evaluate(conn.frame_id, expression: "(() => #{js})()", timeout: 2_000)
    value
  end

  defp wait!(conn, js, timeout \\ 5_000) do
    case Frame.wait_for_function(conn.frame_id, expression: "() => #{js}", is_function: true, timeout: timeout) do
      {:ok, _} -> conn
      {:error, error} -> flunk("timed out waiting for `#{js}`: #{inspect(error)}")
    end
  end

  defp notifs(conn), do: value(conn, "(window.__notifs || []).map(n => ({title: n.title, body: n.body, tag: n.tag}))")
  defp horns(conn), do: value(conn, "window.__horns || []")
  defp title(conn), do: value(conn, "document.title")
  defp icon_href(conn), do: value(conn, ~s|document.querySelector("link[rel=icon]").href|)

  # daisyUI makes the trigger click-through while its dropdown is open (focus inside), so an open
  # menu is closed first — blurring, as clicking elsewhere would.
  defp open_menu(conn) do
    conn
    |> js!("document.activeElement && document.activeElement.blur(); true")
    |> click("#user-avatar")
  end

  # ── 1. permission rows ──────────────────────────────────────────────────────────────────────

  test "the permission rows follow Notification.permission; only Enable asks", ctx do
    conn = open_board(ctx.conn, ctx.x)

    native = value(conn, ~s|"Notification" in window ? Notification.permission : "unsupported"|)
    assert value(conn, "document.documentElement.dataset.notifyPermission") == native

    conn =
      conn
      |> js!(notification_stub("default") <> " true")
      |> open_menu()
      |> assert_has(~s(html[data-notify-permission="default"]))
      |> assert_has(~s(li[data-notify-state="default"] #notify-enable), text: "Enable")
      |> refute_has(~s(li[data-notify-state="granted"]))
      |> refute_has(~s(li[data-notify-state="blocked"]))

    assert value(conn, "window.__permReqs") == nil, "opening the menu must never ask"

    conn =
      conn
      |> click("#notify-enable")
      |> assert_has(~s(html[data-notify-permission="granted"]))

    assert value(conn, "window.__permReqs") == 1

    conn
    |> open_menu()
    |> assert_has(~s(li[data-notify-state="granted"]), text: "On")
    |> js!(~s|window.Notification.permission = "denied"; true|)
    |> open_menu()
    |> assert_has(~s(html[data-notify-permission="denied"]))
    |> assert_has(~s(li[data-notify-state="blocked"]), text: "Blocked in browser settings")
    |> js!("delete window.Notification; true")
    |> open_menu()
    |> assert_has(~s(html[data-notify-permission="unsupported"]))
    |> assert_has(~s(li[data-notify-state="blocked"]), text: "Blocked in browser settings")
  end

  # ── 2–4. focused tab: toasts ────────────────────────────────────────────────────────────────

  test "a focused tab shows a toast and plays the horn, with no count and no OS alert", ctx do
    conn = ctx.conn |> open_board(ctx.x) |> stub(focus: true, permission: "granted")
    change(ctx.cx, :needs_input)

    toast = "#browser-notify-toasts .browser-notify-toast[data-kind=needs_input]"

    conn =
      conn
      |> assert_has(toast, text: ref(ctx.x, ctx.cx))
      |> assert_has(toast, text: "Question from the AI")
      |> assert_has(toast, text: ctx.cx.title)
      |> assert_has("#{toast} [data-action=open]", text: "Open card")
      |> refute_has("#{toast} [data-field=board_name]")
      |> wait!("(window.__horns || []).length === 1")

    assert [horn] = horns(conn)
    assert String.ends_with?(horn, Push.web_sound_path())
    refute String.starts_with?(title(conn), "(")
    assert notifs(conn) == []
  end

  test "toasts stack newest first, name a foreign board, and cap at three", ctx do
    conn = ctx.conn |> open_board(ctx.x) |> stub(focus: true)
    change(ctx.cx, :needs_input)
    conn = assert_has(conn, "#browser-notify-toasts .browser-notify-toast", count: 1)

    change(ctx.cy, :in_review)

    conn
    |> assert_has("#browser-notify-toasts .browser-notify-toast", count: 2)
    |> assert_has(
      "#browser-notify-toasts > .browser-notify-toast:first-child[data-kind=in_review] [data-field=board_name]",
      text: "· #{ctx.y.name}"
    )

    change(ctx.cx2, :in_review)
    change(ctx.cy, :needs_input)

    conn
    |> wait!("(window.__horns || []).length === 4")
    |> assert_has("#browser-notify-toasts .browser-notify-toast", count: 3)
  end

  @tag timeout: 60_000
  test "a toast auto-dismisses after 8s unless hovered", ctx do
    conn = ctx.conn |> open_board(ctx.x) |> stub(focus: true)
    change(ctx.cx, :needs_input)

    conn
    |> assert_has("#browser-notify-toasts .browser-notify-toast")
    |> wait!(~s|document.querySelectorAll("#browser-notify-toasts .browser-notify-toast").length === 0|, 9_000)

    change(ctx.cx, :in_review)
    toast = "#browser-notify-toasts .browser-notify-toast"
    conn = assert_has(conn, toast)

    {:ok, _} = Frame.hover(conn.frame_id, selector: toast, timeout: 2_000)
    Process.sleep(9_000)
    conn = assert_has(conn, toast)

    {:ok, _} = Frame.hover(conn.frame_id, selector: "#top-bar-title", timeout: 2_000)

    wait!(conn, ~s|document.querySelectorAll("#{toast}").length === 0|, 9_000)
  end

  test "a toast's Open card lands on the card's drawer on its own board", ctx do
    conn = ctx.conn |> open_board(ctx.x) |> stub(focus: true)
    change(ctx.cy, :in_review)

    ref_cy = ref(ctx.y, ctx.cy)

    conn
    |> click("#browser-notify-toasts .browser-notify-toast [data-action=open]")
    |> assert_path("/board/#{ctx.y.slug}", query_params: %{card: ref_cy})
    |> assert_has("#card-drawer-title", text: ctx.cy.title)
    |> refute_has("#browser-notify-toasts .browser-notify-toast")
  end

  # ── 5–6. background tab: OS notification, count, favicon dot ────────────────────────────────

  test "a background tab raises OS notifications, counts them in the title and dots the favicon",
       ctx do
    conn = ctx.conn |> open_board(ctx.x) |> stub(focus: false, permission: "granted")
    change(ctx.cx, :needs_input)
    change(ctx.cx2, :in_review)

    conn = wait!(conn, "(window.__notifs || []).length === 2 && (window.__horns || []).length === 2")

    ref_cx = ref(ctx.x, ctx.cx)
    ref_cx2 = ref(ctx.x, ctx.cx2)

    assert notifs(conn) == [
             %{"title" => "Question from the AI", "body" => "#{ref_cx}: #{ctx.cx.title}", "tag" => ref_cx},
             %{"title" => "Ready for your review", "body" => "#{ref_cx2}: #{ctx.cx2.title}", "tag" => ref_cx2}
           ]

    conn = wait!(conn, ~s|document.querySelector("link[rel=icon]").href.startsWith("data:image/png")|)
    assert String.starts_with?(title(conn), "(2) ")
    refute_has(conn, "#browser-notify-toasts .browser-notify-toast")
  end

  test "clicking the OS notification opens the card; focusing the tab clears count and dot", ctx do
    conn = ctx.conn |> open_board(ctx.x) |> stub(focus: false, permission: "granted")
    original_icon = icon_href(conn)
    change(ctx.cy, :in_review)

    conn =
      conn
      |> wait!("(window.__notifs || []).length === 1")
      |> wait!(~s|document.querySelector("link[rel=icon]").href.startsWith("data:")|)
      # Headless focus is not reliable either way, so window.focus() is a no-op here: whether the
      # click focused the window is not what this test asserts.
      |> js!("window.focus = () => {}; window.__notifs[0].instance.onclick(); true")
      |> assert_path("/board/#{ctx.y.slug}", query_params: %{card: ref(ctx.y, ctx.cy)})
      |> assert_has("#card-drawer-title", text: ctx.cy.title)

    # Live navigation rewrote <title> to board Y's; the count survives it until the tab is focused.
    conn = wait!(conn, ~s|document.title === "(1) #{ctx.y.name} · Relay"|)

    conn =
      conn
      |> js!(~s|document.hasFocus = () => true; window.dispatchEvent(new Event("focus")); true|)
      |> wait!(~s|!document.title.startsWith("(")|)

    refute String.starts_with?(icon_href(conn), "data:")
    assert icon_href(conn) == original_icon
  end

  # ── 7–9. sound off, permission denied, own action ──────────────────────────────────────────

  test "with Sound off the toast shows silently and the switch reads off", ctx do
    conn =
      ctx.conn
      |> open_board(ctx.x)
      |> js!(~s|localStorage.setItem("relay:notify-sound", "off"); true|)
      |> reload_page()
      |> assert_has("body .phx-connected")
      |> assert_has("html[data-notify-permission]")
      |> stub(focus: true)

    change(ctx.cx, :needs_input)

    conn = assert_has(conn, "#browser-notify-toasts .browser-notify-toast")
    Process.sleep(300)
    assert horns(conn) == []

    conn = open_menu(conn)
    assert value(conn, ~s|document.getElementById("notify-sound-toggle").checked|) == false
  end

  test "the Sound switch writes the preference", ctx do
    conn = ctx.conn |> open_board(ctx.x) |> open_menu()

    assert value(conn, ~s|document.getElementById("notify-sound-toggle").checked|) == true

    conn = click(conn, "#notify-sound-toggle")
    assert value(conn, ~s|localStorage.getItem("relay:notify-sound")|) == "off"

    conn = conn |> open_menu() |> click("#notify-sound-toggle")
    assert value(conn, ~s|localStorage.getItem("relay:notify-sound")|) == nil
  end

  test "a background tab without permission raises no OS alert but still counts", ctx do
    conn = ctx.conn |> open_board(ctx.x) |> stub(focus: false, permission: "denied")
    change(ctx.cx, :needs_input)

    conn = wait!(conn, ~s|document.title.startsWith("(1) ")|)
    Process.sleep(500)
    assert notifs(conn) == []
  end

  test "the user's own change notifies nobody in their tabs", ctx do
    conn = ctx.conn |> open_board(ctx.x) |> stub(focus: true, permission: "granted")
    change(ctx.cx, :in_review, {:user, ctx.user.id})

    Process.sleep(500)

    conn
    |> refute_has("#browser-notify-toasts .browser-notify-toast")
    |> notifs()
    |> Kernel.==([])
    |> assert()
  end
end
