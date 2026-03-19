defmodule SentientwaveAutomataWeb.Router do
  use SentientwaveAutomataWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SentientwaveAutomataWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :admin_auth do
    plug SentientwaveAutomataWeb.Plugs.RequireAdminAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_admin do
    plug :accepts, ["json"]
    plug :fetch_session
    plug SentientwaveAutomataWeb.Plugs.RequireAdminAPI
  end

  scope "/", SentientwaveAutomataWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
    get "/onboarding/user", UserOnboardingController, :show
  end

  scope "/", SentientwaveAutomataWeb do
    pipe_through [:browser, :admin_auth]

    get "/", PageController, :home
    get "/dashboard", PageController, :dashboard
    get "/onboarding", PageController, :onboarding
    get "/settings/llm", PageController, :llm
    get "/settings/llm/providers/new", PageController, :new_llm_provider
    get "/settings/llm/providers/:id", PageController, :llm_provider
    get "/settings/tools", PageController, :tools
    get "/settings/tools/new", PageController, :new_tool
    get "/settings/tools/:id", PageController, :tool
    post "/settings/llm/providers", PageController, :create_llm_provider
    post "/settings/llm/providers/:id", PageController, :update_llm_provider
    post "/settings/llm/providers/:id/default", PageController, :set_default_llm_provider
    delete "/settings/llm/providers/:id", PageController, :delete_llm_provider
    post "/settings/tools", PageController, :create_tool
    post "/settings/tools/:id", PageController, :update_tool
    delete "/settings/tools/:id", PageController, :delete_tool
  end

  scope "/api/v1", SentientwaveAutomataWeb.API do
    pipe_through :api

    post "/workflows", WorkflowController, :create
    get "/workflows", WorkflowController, :index
    post "/mentions", MentionsController, :create
    post "/onboarding/validate", OnboardingController, :validate
  end

  scope "/api/v1", SentientwaveAutomataWeb.API do
    pipe_through :api_admin

    get "/system/status", SystemController, :status
    get "/directory/users", DirectoryController, :index
    post "/directory/users", DirectoryController, :upsert
    post "/directory/reconcile", DirectoryController, :reconcile
    get "/agent-runs", AgentRunsController, :index
    get "/agent-runs/:id", AgentRunsController, :show
    post "/agent-memories", AgentMemoriesController, :create
    get "/agent-memories/search", AgentMemoriesController, :search
  end
end
