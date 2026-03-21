defmodule SentientwaveAutomataWeb.PageControllerTest do
  use SentientwaveAutomataWeb.ConnCase

  import Plug.Test, only: [init_test_session: 2]

  alias SentientwaveAutomata.Agents

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

    assert html_response(conn, 200) =~ "LLM Provider Management"
  end

  test "GET /settings/llm/providers/new includes Anthropic in provider options", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/llm/providers/new")

    body = html_response(conn, 200)
    assert body =~ "Add LLM Provider"
    assert body =~ "Anthropic"
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
    assert body =~ "LLM Trace Explorer"
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
    assert body =~ "LLM Trace Detail"
    assert body =~ "missing_api_key"
    assert body =~ "gpt-4o-mini"
  end
end
