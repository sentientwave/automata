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
    get "/directory/users", PageController, :directory
    get "/directory/users/new", PageController, :new_directory_user
    get "/directory/users/:localpart", PageController, :directory_user
    get "/directory/users/:localpart/tasks/new", PageController, :new_directory_task
    get "/directory/users/:localpart/tasks/:id", PageController, :directory_task
    get "/constitution", PageController, :constitution
    get "/constitution/laws/:id", PageController, :constitution_law
    get "/constitution/proposals/new/:proposal_type", PageController, :new_constitution_proposal
    get "/constitution/proposals/:id", PageController, :constitution_proposal
    get "/constitution/roles", PageController, :constitution_roles
    get "/constitution/roles/:id", PageController, :constitution_role
    get "/settings/skills", PageController, :skills
    get "/settings/skills/new", PageController, :new_skill
    get "/settings/skills/:id", PageController, :skill
    get "/settings/llm", PageController, :llm
    get "/settings/llm/providers/new", PageController, :new_llm_provider
    get "/settings/llm/providers/:id", PageController, :llm_provider
    get "/observability/llm-traces", PageController, :llm_traces
    get "/observability/llm-traces/:id", PageController, :llm_trace
    get "/settings/tools", PageController, :tools
    get "/settings/tools/new", PageController, :new_tool
    get "/settings/tools/:id", PageController, :tool
    post "/settings/llm/providers", PageController, :create_llm_provider
    post "/settings/llm/providers/:id", PageController, :update_llm_provider
    post "/settings/llm/providers/:id/default", PageController, :set_default_llm_provider
    delete "/settings/llm/providers/:id", PageController, :delete_llm_provider
    post "/directory/users", PageController, :create_directory_user
    post "/directory/users/:localpart", PageController, :update_directory_user

    post "/directory/users/:localpart/rotate-password",
         PageController,
         :rotate_directory_user_password

    delete "/directory/users/:localpart", PageController, :delete_directory_user

    post "/directory/users/:localpart/agent-profile",
         PageController,
         :update_directory_agent_profile

    post "/directory/users/:localpart/tool-permissions",
         PageController,
         :update_directory_tool_permission

    post "/directory/users/:localpart/tasks", PageController, :create_directory_task
    post "/directory/users/:localpart/tasks/:id", PageController, :update_directory_task
    post "/directory/users/:localpart/tasks/:id/toggle", PageController, :toggle_directory_task
    delete "/directory/users/:localpart/tasks/:id", PageController, :delete_directory_task
    post "/constitution/proposals", PageController, :create_constitution_proposal
    post "/constitution/roles", PageController, :create_constitution_role
    post "/constitution/roles/:id", PageController, :update_constitution_role
    post "/constitution/roles/:id/assignments", PageController, :assign_constitution_role

    post "/constitution/roles/:id/assignments/:assignment_id/revoke",
         PageController,
         :revoke_constitution_role_assignment

    post "/settings/skills", PageController, :create_skill
    post "/settings/skills/:id", PageController, :update_skill
    post "/settings/skills/:id/designations", PageController, :designate_skill

    post "/settings/skills/:id/designations/:designation_id/rollback",
         PageController,
         :rollback_skill_designation

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
