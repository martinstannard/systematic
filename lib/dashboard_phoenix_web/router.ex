defmodule DashboardPhoenixWeb.Router do
  @moduledoc """
  Application routing configuration for the dashboard.
  
  Defines HTTP request routing, authentication pipelines, and access control.
  Separates public routes (login) from protected routes (main dashboard) with
  optional token-based authentication.
  """
  use DashboardPhoenixWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {DashboardPhoenixWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :authenticated do
    plug(DashboardPhoenixWeb.Plugs.Auth)
  end

  # Public routes (no auth required)
  scope "/", DashboardPhoenixWeb do
    pipe_through(:browser)

    get("/page", PageController, :home)
    get("/login", AuthController, :login)
    post("/login", AuthController, :authenticate)
    get("/logout", AuthController, :logout)
  end

  # Protected routes (auth required when DASHBOARD_AUTH_TOKEN is set)
  scope "/", DashboardPhoenixWeb do
    pipe_through([:browser, :authenticated])

    live("/", HomeLive)
  end

  # Other scopes may use custom stacks.
  # scope "/api", DashboardPhoenixWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:dashboard_phoenix, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: DashboardPhoenixWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
