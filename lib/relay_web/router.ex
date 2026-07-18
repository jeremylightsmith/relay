defmodule RelayWeb.Router do
  use RelayWeb, :router

  import PhoenixStorybook.Router
  import RelayWeb.Auth

  alias RelayWeb.Plugs.ApiLogger
  alias RelayWeb.Plugs.Embed

  @content_security_policy "default-src 'self'; " <>
                             "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; " <>
                             "style-src 'self' 'unsafe-inline'; " <>
                             "img-src 'self' data: blob: https://*.googleusercontent.com; " <>
                             "font-src 'self'; " <>
                             "connect-src 'self' blob: ws: wss:; " <>
                             "base-uri 'self'; " <>
                             "form-action 'self'; " <>
                             "frame-ancestors 'self';"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug Embed
    plug :fetch_live_flash
    plug :put_root_layout, html: {RelayWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
    plug :fetch_current_scope
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug ApiLogger
  end

  pipeline :api_auth do
    plug RelayWeb.ApiAuth
  end

  pipeline :api_user_auth do
    plug RelayWeb.ApiUserAuth
  end

  pipeline :native_auth do
    plug :accepts, ["json"]
    plug :fetch_session
    plug ApiLogger
  end

  # The native shell's device-registration API (RLY-81). Authenticated by the
  # session cookie F2's native sign-in issued, NOT F4 (RLY-80)'s `relayu_…`
  # bearer token below — the Flutter shell has no bearer token to send yet
  # (native sign-in mints only a session cookie). This is a deliberate, known
  # second credential on the `/api/all` prefix pending consolidation onto F4's
  # bearer scope (see plan.md's Deviation 1 / Deferred).
  pipeline :native_user_auth do
    plug :accepts, ["json"]
    plug :fetch_session
    plug ApiLogger
    plug :fetch_current_scope
    plug RelayWeb.Plugs.RequireApiUser
  end

  pipeline :require_authenticated_user do
    plug :require_authenticated
  end

  pipeline :require_superadmin_user do
    plug :require_superadmin
  end

  scope "/", RelayWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/privacy", PageController, :privacy
    get "/terms", PageController, :terms
    get "/docs", DocsController, :index
    get "/docs/:page", DocsController, :show
    delete "/logout", AuthController, :delete

    # In test, RelayWeb.LiveAcceptance must run first so the auth hook's DB query
    # runs inside the browser test's shared sandbox transaction.
    live_session :require_authenticated,
      on_mount:
        if(Application.compile_env(:relay, :sql_sandbox),
          do: [RelayWeb.LiveAcceptance],
          else: []
        ) ++ [{RelayWeb.Auth, :require_authenticated}, {RelayWeb.Auth, :mount_embed}] do
      live "/boards", BoardsLive
      live "/board/:slug", BoardLive
      live "/board/:slug/settings", BoardSettingsLive
      live "/board/:slug/runners", BoardRunnersLive
      live "/board/:slug/flows/:key", FlowEditorLive

      # RLY-87 — the native app's card host: BoardLive rendering the drawer alone.
      # Chromeless by construction (the :card mount forces embed: true), so it can
      # never render half-native-half-web. This is a **native-host surface, not a
      # browser destination** — the web opens a card at /board/:slug?card=:ref.
      live "/cards/:ref", BoardLive, :card
    end
  end

  scope "/", RelayWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/board", BoardRedirectController, :index
    get "/attachments/:id", AttachmentController, :show
  end

  scope "/admin", RelayWeb.Admin do
    pipe_through [:browser, :require_superadmin_user]

    live_session :admin,
      on_mount:
        if(Application.compile_env(:relay, :sql_sandbox),
          do: [RelayWeb.LiveAcceptance],
          else: []
        ) ++ [{RelayWeb.Auth, :require_superadmin}] do
      live "/api", ApiLive
    end
  end

  scope "/auth", RelayWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  scope "/api/auth/native", RelayWeb do
    pipe_through :native_auth

    post "/google", NativeAuthController, :google
    get "/me", NativeAuthController, :me
  end

  # RLY-81 device registration. Shares the `/api/all` prefix with the bearer-token scope below
  # but is authenticated separately (session cookie, not `relayu_…` bearer) — see the
  # `:native_user_auth` pipeline doc above for why, and plan.md's Deviation 1 for the tracked
  # follow-up to consolidate onto one credential.
  scope "/api/all", RelayWeb.Api do
    pipe_through :native_user_auth

    post "/devices", DeviceController, :create
    delete "/devices/:token", DeviceController, :delete
  end

  # RLY-80 — the native app's human-authed decision surface. Deliberately separate from the
  # agent-only board-key /api scope below: different credential, different actor, and it must
  # not collide with the board API's payloads (RLY-67). RLY-126 extends this same scoped
  # exception (ADR 0001) with the native New-card sheet's create path.
  scope "/api/all", RelayWeb.Api do
    pipe_through [:api, :api_user_auth]

    post "/cards", AllController, :create
    get "/feed", AllController, :feed
    get "/cards/:ref", AllController, :show
    post "/cards/:ref/approve", AllController, :approve
    post "/cards/:ref/reject", AllController, :reject
    post "/cards/:ref/answer", AllController, :answer
  end

  scope "/api", RelayWeb.Api do
    pipe_through [:api, :api_auth]

    get "/board", BoardController, :show
    get "/board/version", BoardController, :version
    post "/board/logs", BoardController, :logs
    post "/board/heartbeat", BoardController, :heartbeat
    get "/cards", CardController, :index
    post "/cards", CardController, :create
    get "/cards/:ref", CardController, :show
    patch "/cards/:ref", CardController, :update
    patch "/cards/:ref/sub-tasks/:id", CardController, :toggle_sub_task
    post "/cards/:ref/move", CardController, :move
    post "/cards/:ref/comments", CardController, :comments
    post "/cards/:ref/attachments", CardController, :attachments
    post "/cards/:ref/needs-input", CardController, :needs_input
    post "/cards/:ref/approve", CardController, :approve
    post "/cards/:ref/reject", CardController, :reject
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:relay, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RelayWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/" do
      storybook_assets()
    end

    scope "/", RelayWeb do
      pipe_through :browser
      live_storybook "/storybook", backend_module: RelayWeb.Storybook
    end

    # Dev/test-only login bypass — the acceptance smoke and local
    # development sign in here instead of real Google.
    scope "/dev", RelayWeb do
      pipe_through :browser

      get "/login", DevLoginController, :create
    end
  end
end
