defmodule SentientwaveAutomataWeb.PageControllerTest do
  use SentientwaveAutomataWeb.ConnCase

  import Plug.Test, only: [init_test_session: 2]

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Settings

  test "GET / redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "GET / redirects to dashboard when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/")

    assert redirected_to(conn) == "/dashboard"
  end

  test "GET /dashboard renders dashboard when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/dashboard")

    assert html_response(conn, 200) =~ "Admin Dashboard"
  end

  test "GET /settings/llm renders llm page when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/llm")

    assert html_response(conn, 200) =~ "Provider Management"
  end

  test "GET /settings/llm/providers/new includes Anthropic in provider options", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/llm/providers/new")

    body = html_response(conn, 200)
    assert body =~ "Add Provider"
    assert body =~ "Anthropic"
  end

  test "GET /settings/llm/providers/new includes Google Gemini in provider options", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/llm/providers/new")

    body = html_response(conn, 200)
    assert body =~ "Add Provider"
    assert body =~ "Google Gemini"
  end

  test "GET /settings/llm/providers/new with Gemini preset shows Gemini setup guidance", %{
    conn: conn
  } do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/llm/providers/new?provider=gemini")

    body = html_response(conn, 200)
    assert body =~ "Quick Presets"
    assert body =~ "Google Gemini"
    assert body =~ "Gemini generateContent API"
    assert body =~ "gemini-3.1-pro-preview"
    assert body =~ "x-goog-api-key"
    assert body =~ "generativelanguage.googleapis.com/v1beta"
  end

  test "GET /settings/llm/providers/new includes Cerebras in provider options", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/llm/providers/new")

    body = html_response(conn, 200)
    assert body =~ "Add Provider"
    assert body =~ "Cerebras"
  end

  test "GET /settings/llm renders humanized Gemini provider labels", %{conn: conn} do
    assert {:ok, _provider} =
             Settings.create_llm_provider_config(%{
               "name" => "Gemini Primary",
               "slug" => "gemini-primary-ui-test",
               "provider" => "gemini",
               "model" => "gemini-3.1-pro-preview",
               "base_url" => "https://generativelanguage.googleapis.com/v1beta",
               "api_token" => "gemini-ui-test-key",
               "enabled" => true,
               "is_default" => true
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/llm")

    body = html_response(conn, 200)
    assert body =~ "Gemini Primary"
    assert body =~ "Google Gemini"
  end

  test "GET /settings/llm/providers/:id shows Gemini setup guidance for a persisted provider", %{
    conn: conn
  } do
    assert {:ok, provider} =
             Settings.create_llm_provider_config(%{
               "name" => "Gemini Detail",
               "slug" => "gemini-detail-ui-test",
               "provider" => "gemini",
               "model" => "gemini-3.1-pro-preview",
               "base_url" => "https://generativelanguage.googleapis.com/v1beta",
               "api_token" => "gemini-detail-key",
               "enabled" => true,
               "is_default" => false
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/llm/providers/#{provider.id}")

    body = html_response(conn, 200)
    assert body =~ "Edit Provider: Gemini Detail"
    assert body =~ "Google Gemini"
    assert body =~ "Gemini generateContent API"
    assert body =~ "x-goog-api-key"
    assert body =~ "gemini-3.1-pro-preview"
  end

  test "GET /settings/skills renders skill catalog when authenticated", %{conn: conn} do
    assert {:ok, _skill} =
             Agents.create_skill(%{
               "name" => "Page Test Skill",
               "markdown_body" => """
               # Skill: Page Test Skill

               Keep work organized.

               - summarize
               """,
               "enabled" => true
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/skills")

    body = html_response(conn, 200)
    assert body =~ "Skill Catalog"
    assert body =~ "Page Test Skill"
  end

  test "GET /settings/tools renders tools page when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/tools")

    assert html_response(conn, 200) =~ "Tool Management"
  end

  test "GET /directory/users renders directory page when authenticated", %{conn: conn} do
    assert {:ok, _user} =
             Directory.upsert_user(%{
               "localpart" => "directory-human",
               "kind" => "person",
               "display_name" => "Directory Human",
               "password" => "VerySecurePass123!"
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/directory/users")

    body = html_response(conn, 200)
    assert body =~ "Directory"
    assert body =~ "directory-human"
  end

  test "POST /directory/users creates a service account", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> post(~p"/directory/users", %{
        "user" => %{
          "localpart" => "svc-bot",
          "kind" => "service",
          "display_name" => "Service Bot",
          "admin" => "false"
        }
      })

    assert redirected_to(conn) == "/directory/users/svc-bot"
    assert %{kind: :service} = Directory.get_user("svc-bot")
  end

  test "directory user detail hides agent panels for service accounts", %{conn: conn} do
    assert {:ok, _user} =
             Directory.upsert_user(%{
               "localpart" => "service-runner",
               "kind" => "service",
               "display_name" => "Service Runner",
               "password" => "VerySecurePass123!"
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/directory/users/service-runner")

    body = html_response(conn, 200)
    assert body =~ "Matrix Account Summary"
    refute body =~ "Agent Runtime Settings"
    refute body =~ "Designated Tools"
  end

  test "directory user detail shows agent settings, tools, and tasks", %{conn: conn} do
    assert {:ok, _directory_user} =
             Directory.upsert_user(%{
               "localpart" => "ops-agent",
               "kind" => "agent",
               "display_name" => "Ops Agent",
               "password" => "VerySecurePass123!"
             })

    assert {:ok, agent} =
             Agents.upsert_agent(%{
               slug: "ops-agent",
               kind: :agent,
               display_name: "Ops Agent",
               matrix_localpart: "ops-agent",
               status: :active
             })

    assert {:ok, _wallet} =
             Agents.upsert_agent_wallet(agent.id, %{
               kind: "personal",
               status: "active",
               matrix_credentials: %{
                 localpart: "ops-agent",
                 mxid: "@ops-agent:localhost",
                 password: "VerySecurePass123!",
                 homeserver_url: "http://localhost:8008"
               },
               metadata: %{}
             })

    assert {:ok, _tool} =
             Settings.create_tool_config(%{
               "name" => "Brave Search",
               "slug" => "brave-search-page-test",
               "tool_name" => "brave_search",
               "base_url" => "https://api.search.brave.com",
               "enabled" => true
             })

    assert {:ok, _permission} =
             Agents.set_tool_permission(%{
               agent_id: agent.id,
               tool_name: "brave_search",
               scope: "default",
               allowed: false,
               constraints: %{}
             })

    assert {:ok, _task} =
             Agents.create_scheduled_task(agent.id, %{
               "name" => "Weekly Summary",
               "enabled" => "true",
               "task_type" => "run_agent_prompt",
               "schedule_type" => "weekly",
               "schedule_interval" => "1",
               "schedule_hour" => "9",
               "schedule_minute" => "0",
               "schedule_weekday" => "1",
               "timezone" => "Etc/UTC",
               "prompt_body" => "Share the summary"
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/directory/users/ops-agent")

    body = html_response(conn, 200)
    assert body =~ "Agent Runtime Settings"
    assert body =~ "Designated Tools"
    assert body =~ "Scheduled Tasks"
    assert body =~ "Weekly Summary"
    assert body =~ "Brave Search"
  end

  test "POST /settings/skills creates a new skill", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> post(~p"/settings/skills", %{
        "skill" => %{
          "name" => "Created From Controller",
          "summary" => "Controller summary",
          "tags" => "ops, quality",
          "enabled" => "1",
          "markdown_body" => """
          # Skill: Created From Controller

          This is a controller-generated skill.

          - summarize requests
          """
        }
      })

    assert redirected_to(conn) =~ "/settings/skills/"

    [skill] = Agents.list_skills(q: "Created From Controller")
    assert skill.metadata["summary"] == "Controller summary"
    assert skill.metadata["tags"] == ["ops", "quality"]
  end

  test "skill detail shows designations and allows rollback flow", %{conn: conn} do
    assert {:ok, agent} =
             Agents.upsert_agent(%{
               slug: "page-skill-agent",
               kind: :agent,
               display_name: "Page Skill Agent",
               matrix_localpart: "page-skill-agent",
               status: :active
             })

    assert {:ok, skill} =
             Agents.create_skill(%{
               "name" => "Detail Skill",
               "markdown_body" => """
               # Skill: Detail Skill

               A detail view skill.

               - route work
               """,
               "enabled" => true
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> post(~p"/settings/skills/#{skill.id}/designations", %{
        "designation" => %{"agent_id" => agent.id}
      })

    assert redirected_to(conn) == "/settings/skills/#{skill.id}"
    [designation] = Agents.list_skill_designations(skill.id, status: :active)

    detail_conn =
      build_conn()
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/skills/#{skill.id}")

    detail_body = html_response(detail_conn, 200)
    assert detail_body =~ "Designation History"
    assert detail_body =~ "Page Skill Agent"

    rollback_conn =
      build_conn()
      |> init_test_session(automata_admin_authenticated: true)
      |> post(~p"/settings/skills/#{skill.id}/designations/#{designation.id}/rollback")

    assert redirected_to(rollback_conn) == "/settings/skills/#{skill.id}"
    assert [] == Agents.list_skill_designations(skill.id, status: :active)
  end

  test "GET /observability/llm-traces renders trace explorer when authenticated", %{conn: conn} do
    assert {:ok, _trace} =
             Agents.create_llm_trace(%{
               provider: "local",
               model: "local-default",
               call_kind: "response",
               sequence_index: 0,
               status: "ok",
               requester_kind: "person",
               requester_mxid: "@mio:localhost",
               room_id: "!room:localhost",
               conversation_scope: "room",
               request_payload: %{"messages" => [%{"role" => "user", "content" => "hello"}]},
               response_payload: %{"content" => "hi"},
               requested_at: DateTime.utc_now()
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/observability/llm-traces", %{"filters" => %{"q" => "hello"}})

    body = html_response(conn, 200)
    assert body =~ "Trace Explorer"
    assert body =~ "@mio:localhost"
  end

  test "GET /observability/llm-traces/:id renders trace detail when authenticated", %{conn: conn} do
    assert {:ok, trace} =
             Agents.create_llm_trace(%{
               provider: "openai",
               model: "gpt-4o-mini",
               call_kind: "tool_planner",
               sequence_index: 0,
               status: "error",
               requester_kind: "agent",
               requester_mxid: "@automata:localhost",
               room_id: "!ops:localhost",
               conversation_scope: "private_message",
               request_payload: %{
                 "messages" => [%{"role" => "user", "content" => "search weather"}]
               },
               error_payload: %{"reason" => "missing_api_key"},
               requested_at: DateTime.utc_now()
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/observability/llm-traces/#{trace.id}")

    body = html_response(conn, 200)
    assert body =~ "Trace Detail"
    assert body =~ "missing_api_key"
    assert body =~ "gpt-4o-mini"
  end
end
