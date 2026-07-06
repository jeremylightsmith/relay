defmodule RelayWeb.Router do
  use RelayWeb, :router

  import PhoenixStorybook.Router

  @content_security_policy "default-src 'self'; " <>
                             "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; " <>
                             "style-src 'self' 'unsafe-inline'; " <>
                             "img-src 'self' data: blob:; " <>
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
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RelayWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", RelayWeb do
  #   pipe_through :api
  # end

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
  end
end
