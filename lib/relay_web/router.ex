defmodule RelayWeb.Router do
  use RelayWeb, :router

  import PhoenixStorybook.Router
  import RelayWeb.Auth

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
    plug :fetch_live_flash
    plug :put_root_layout, html: {RelayWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
    plug :fetch_current_scope
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug RelayWeb.Plugs.ApiLogger
  end

  pipeline :api_auth do
    plug RelayWeb.ApiAuth
  end

  pipeline :require_authenticated_user do
    plug :require_authenticated
  end

  scope "/", RelayWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/privacy", PageController, :privacy
    get "/terms", PageController, :terms
    get "/docs/api", DocsController, :api
    delete "/logout", AuthController, :delete

    # In test, RelayWeb.LiveAcceptance must run first so the auth hook's DB query
    # runs inside the browser test's shared sandbox transaction.
    live_session :require_authenticated,
      on_mount:
        if(Application.compile_env(:relay, :sql_sandbox),
          do: [RelayWeb.LiveAcceptance],
          else: []
        ) ++ [{RelayWeb.Auth, :require_authenticated}] do
      live "/boards", BoardsLive
      live "/board/:slug", BoardLive
      live "/board/:slug/settings", BoardSettingsLive
    end
  end

  scope "/", RelayWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/board", BoardRedirectController, :index
  end

  scope "/auth", RelayWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  scope "/api", RelayWeb.Api do
    pipe_through [:api, :api_auth]

    get "/board", BoardController, :show
    get "/cards", CardController, :index
    post "/cards", CardController, :create
    get "/cards/:ref", CardController, :show
    patch "/cards/:ref", CardController, :update
    post "/cards/:ref/move", CardController, :move
    post "/cards/:ref/comments", CardController, :comments
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
