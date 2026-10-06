defmodule RelayWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.Layouts

  @scope %{user: %{id: 1, email: "a@b.co", name: "Ada Lovelace", avatar_url: nil}}

  defp render_app(assigns) do
    assigns =
      Map.merge(%{flash: %{}, current_scope: @scope, inner_block: nil}, assigns)

    render_component(&Layouts.app/1, assigns)
  end

  defp inner_block_slot do
    [%{__slot__: :inner_block, inner_block: fn _, _ -> Phoenix.HTML.raw("x") end}]
  end

  defp render_public_board(assigns) do
    assigns =
      Map.merge(
        %{
          flash: %{},
          current_scope: nil,
          board_name: "Roadmap",
          public_path: "/board/roadmap/public",
          inner_block: nil
        },
        assigns
      )

    render_component(&Layouts.public_board/1, assigns)
  end

  test "always renders the 53px bar with the logo linking to /boards" do
    html = render_app(%{inner_block: inner_block_slot()})

    assert html =~ ~s(id="top-bar")
    assert html =~ "height:53px"
    assert html =~ ~s(id="top-bar-logo")
    assert html =~ ~s(href="/boards")
  end

  # RE393: every embed-only mobile restyle is scoped under main[data-embed].
  test "embedded, <main> carries data-embed" do
    html = render_app(%{embed: true, inner_block: inner_block_slot()})

    assert [_main] = html |> LazyHTML.from_fragment() |> LazyHTML.query("main[data-embed]") |> Enum.to_list()
  end

  test "not embedded, <main> carries no data-embed" do
    html = render_app(%{embed: false, inner_block: inner_block_slot()})

    main = html |> LazyHTML.from_fragment() |> LazyHTML.query("main")
    assert Enum.count(main) == 1
    assert LazyHTML.attribute(main, "data-embed") == []
  end

  test "hides the wordmark text below md while keeping the logo icon" do
    html = render_app(%{inner_block: inner_block_slot()})

    # wordmark span is hidden until md; logo img is always present
    assert html =~ ~s(class="hidden md:inline text-[15px] font-semibold tracking-[-0.02em]")
    assert html =~ ~s(alt="Relay")
  end

  test "reconnect banners read 'Relay is updating' as calm info alerts" do
    html = render_app(%{inner_block: inner_block_slot()})

    assert html =~ ~s(id="client-error")
    assert html =~ ~s(id="server-error")
    assert html =~ "Relay is updating"
    assert html =~ "Standby"
    assert html =~ "alert-info"

    # the old red-error copy is gone
    refute html =~ "We can't find the internet"
    refute html =~ "Something went wrong"

    # the disconnect/connect visibility hooks are preserved
    assert html =~ "phx-disconnected"
    assert html =~ "phx-connected"
  end

  test "renders the avatar dropdown with sign out" do
    html = render_app(%{inner_block: inner_block_slot()})

    assert html =~ ~s(id="account-menu")
    assert html =~ ~s(id="sign-out")
    assert html =~ ~s(data-phx-theme="dark")
    # initials fallback (no avatar_url)
    assert html =~ "AL"
  end

  test "the avatar menu shows the Admin entry only for the superadmin (RE353)" do
    superadmin = %Schemas.Scope{
      user: %Schemas.User{
        id: 1,
        email: hd(Schemas.Scope.superadmin_emails()),
        name: "Super Admin",
        avatar_url: nil
      }
    }

    member = %Schemas.Scope{
      user: %Schemas.User{id: 2, email: "a@b.co", name: "Ada Lovelace", avatar_url: nil}
    }

    html = render_app(%{current_scope: superadmin, inner_block: inner_block_slot()})
    assert html =~ ~s(id="admin-link")
    assert html =~ ~s(href="/admin")

    html = render_app(%{current_scope: member, inner_block: inner_block_slot()})
    refute html =~ ~s(id="admin-link")
  end

  test "the theme toggle is a labelled radiogroup whose indicator tracks data-theme-pref" do
    html = render_app(%{inner_block: inner_block_slot()})

    assert html =~ ~s(role="radiogroup")
    assert html =~ ~s(aria-label="Theme")

    for {theme, label} <- [
          {"system", "Use the system theme"},
          {"light", "Use the light theme"},
          {"dark", "Use the dark theme"}
        ] do
      assert html =~ ~s(data-phx-theme="#{theme}")
      assert html =~ ~s(aria-label="#{label}")
    end

    # RE237: the indicator keys off the raw PREFERENCE, not the resolved theme — otherwise
    # "system" and the resolved theme fight and it lands on the wrong third.
    assert html =~ "[[data-theme-pref=light]_&]:left-1/3"
    assert html =~ "[[data-theme-pref=dark]_&]:left-2/3"
    refute html =~ "[[data-theme=light]_&]"
    # brightness-200 was a light-only hack that blows out on dark.
    refute html =~ "brightness-200"
  end

  test "the header logo ships both variants and swaps on the dark theme" do
    html = render_app(%{inner_block: inner_block_slot()})

    assert html =~ ~s(src="/images/logo_light_128.png")
    assert html =~ ~s(src="/images/logo_dark_128.png")
    assert html =~ "dark:hidden"
    assert html =~ "hidden dark:block"
  end

  test "the public board canvas is mapped by role (base-200 page canvas), not by inline value" do
    html = render_public_board(%{inner_block: inner_block_slot()})

    assert html =~ "bg-base-200"
    # RE237: field-hover is the hover/inset-fill token, not the page-canvas token — using it
    # here made the canvas identical to (and lighter than) the card borders sitting on it.
    refute html =~ "background:var(--color-field-hover)"
    refute html =~ "oklch("
  end

  describe "crumbs (RE334)" do
    @boards_crumb %{
      label: "Boards",
      to: "/boards",
      id: "top-bar-crumb-boards",
      icon: "hero-squares-2x2"
    }

    test "renders the trail after the logo and before the title, behind the divider" do
      html = render_app(%{inner_block: inner_block_slot(), crumbs: [@boards_crumb]})

      assert html =~ ~s(id="top-bar-divider")
      assert html =~ ~s(id="top-bar-crumb")

      {logo, _} = :binary.match(html, ~s(id="top-bar-logo"))
      {crumb, _} = :binary.match(html, ~s(id="top-bar-crumb-boards"))
      {title, _} = :binary.match(html, ~s(id="top-bar-title"))
      assert logo < crumb and crumb < title
    end

    test "renders no trail and no divider when there are no crumbs and no title" do
      html = render_app(%{inner_block: inner_block_slot()})

      refute html =~ ~s(id="top-bar-divider")
      refute html =~ ~s(id="top-bar-crumb")
    end
  end

  describe "Suggest an idea (RE397)" do
    @public_board "https://relayboard.fly.dev/board/relay/public"

    defp account_menu(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("#account-menu")

    test "renders the link in the account menu, opening the URL in a new tab" do
      html = render_app(%{feedback_url: @public_board, inner_block: inner_block_slot()})

      link = html |> account_menu() |> LazyHTML.query("a#suggest-idea-link")
      assert Enum.count(link) == 1
      assert LazyHTML.attribute(link, "href") == [@public_board]
      assert LazyHTML.attribute(link, "target") == ["_blank"]
      assert LazyHTML.attribute(link, "rel") == ["noopener"]
      assert LazyHTML.text(link) =~ "Suggest an idea"
    end

    test "sits between the theme toggle and sign out, with a bulb and a trailing external arrow" do
      html = render_app(%{feedback_url: @public_board, inner_block: inner_block_slot()})

      {theme, _} = :binary.match(html, ~s(data-phx-theme="dark"))
      {suggest, _} = :binary.match(html, "suggest-idea-link")
      {sign_out, _} = :binary.match(html, ~s(id="sign-out"))
      assert theme < suggest and suggest < sign_out

      link = html |> account_menu() |> LazyHTML.query("a#suggest-idea-link")

      bulb = LazyHTML.query(link, ".hero-light-bulb")
      assert Enum.count(bulb) == 1
      assert bulb |> LazyHTML.attribute("class") |> hd() |> String.split() |> Enum.member?("size-4")

      arrow = LazyHTML.query(link, ".hero-arrow-top-right-on-square")
      assert Enum.count(arrow) == 1
      arrow_classes = arrow |> LazyHTML.attribute("class") |> hd() |> String.split()

      for class <- ["ml-auto", "size-3.5", "text-base-content/45"] do
        assert class in arrow_classes, "expected #{class} on the arrow, got #{inspect(arrow_classes)}"
      end
    end

    test "is wrapped by exactly two dividers, one directly before and one directly after its <li>" do
      html = render_app(%{feedback_url: @public_board, inner_block: inner_block_slot()})

      menu = account_menu(html)
      assert menu |> LazyHTML.query(".divider") |> Enum.count() == 2

      before = LazyHTML.query(menu, "li.divider + li:has(#suggest-idea-link)")
      assert Enum.count(before) == 1

      after_ = LazyHTML.query(menu, "li:has(#suggest-idea-link) + li.divider")
      assert Enum.count(after_) == 1

      divider_classes = menu |> LazyHTML.query(".divider") |> LazyHTML.attribute("class") |> hd() |> String.split()
      for class <- ["divider", "my-1", "h-px"], do: assert(class in divider_classes)
    end

    test "a nil feedback_url renders no link, no label and no dividers" do
      html = render_app(%{feedback_url: nil, inner_block: inner_block_slot()})

      refute html =~ "suggest-idea-link"
      refute html =~ "Suggest an idea"
      assert html |> account_menu() |> LazyHTML.query(".divider") |> Enum.count() == 0
      assert html =~ ~s(id="sign-out")
    end

    test "with no feedback_url assign it falls back to config, which test leaves unset" do
      html = render_app(%{inner_block: inner_block_slot()})

      refute html =~ "suggest-idea-link"
    end
  end

  describe "browser notifications (RE399)" do
    defp doc(html), do: LazyHTML.from_fragment(html)

    test "the account menu shows the Notifications section, in order, right above Theme" do
      html = render_app(%{inner_block: inner_block_slot()})
      menu = html |> doc() |> LazyHTML.query("#account-menu")

      assert menu |> LazyHTML.query(~s(li[data-notify-state="default"] button#notify-enable)) |> LazyHTML.text() =~
               "Enable"

      assert menu |> LazyHTML.query(~s(li[data-notify-state="granted"])) |> Enum.count() == 1

      blocked = LazyHTML.query(menu, ~s(li[data-notify-state="blocked"].menu-disabled))
      assert LazyHTML.text(blocked) =~ "Blocked in browser settings"

      toggle = LazyHTML.query(menu, "input#notify-sound-toggle.toggle.toggle-xs.toggle-primary[checked]")
      assert Enum.count(toggle) == 1

      positions =
        Enum.map(
          [
            ~s(uppercase tracking-wider">Notifications),
            ~s(data-notify-state="default"),
            ~s(id="notify-enable"),
            ~s(data-notify-state="granted"),
            ~s(data-notify-state="blocked"),
            ~s(id="notify-sound-toggle"),
            ~s(uppercase tracking-wider">Theme)
          ],
          fn needle ->
            assert {pos, _} = :binary.match(html, needle), "missing #{needle}"
            pos
          end
        )

      assert positions == Enum.sort(positions)
    end

    test "renders the hook element, both toast templates and the toast container" do
      html = render_app(%{board_slug: "my-board", inner_block: inner_block_slot()})
      d = doc(html)

      hook =
        LazyHTML.query(
          d,
          ~s(#browser-notify[phx-hook="BrowserNotify"][data-sound="#{Relay.Push.web_sound_path()}"][data-board-slug="my-board"])
        )

      assert Enum.count(hook) == 1
      assert d |> LazyHTML.query("template#browser-notify-toast-needs_input") |> Enum.count() == 1
      assert d |> LazyHTML.query("template#browser-notify-toast-in_review") |> Enum.count() == 1
      assert d |> LazyHTML.query(~s(#browser-notify-toasts[phx-update="ignore"])) |> Enum.count() == 1
    end

    test "without a board_slug the hook element carries no data-board-slug" do
      d = doc(render_app(%{inner_block: inner_block_slot()}))

      hook = LazyHTML.query(d, "#browser-notify")
      assert Enum.count(hook) == 1
      assert LazyHTML.attribute(hook, "data-board-slug") == []
    end

    test "embed renders none of the notification surface" do
      html = render_app(%{embed: true, inner_block: inner_block_slot()})

      refute html =~ ~s(id="browser-notify")
      refute html =~ ~s(id="browser-notify-toasts")
      refute html =~ ~s(id="notify-enable")
    end

    test "a signed-out render has no hook element" do
      html = render_app(%{current_scope: nil, inner_block: inner_block_slot()})

      refute html =~ ~s(id="browser-notify")
    end
  end
end
