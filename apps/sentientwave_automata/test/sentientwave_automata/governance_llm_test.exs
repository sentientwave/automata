defmodule SentientwaveAutomata.GovernanceLLMTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.LLM.Client
  alias SentientwaveAutomata.Governance
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Settings

  describe "constitution prompt injection" do
    test "injects the active constitution snapshot into every model call and trace context" do
      suffix = System.unique_integer([:positive])
      localpart = "constitution-agent-#{suffix}"

      assert {:ok, _user} =
               Directory.upsert_user(%{
                 localpart: localpart,
                 kind: :agent,
                 display_name: "Constitution Agent",
                 password: "VerySecurePass123!"
               })

      assert {:ok, agent} =
               Agents.upsert_agent(%{
                 slug: localpart,
                 kind: :agent,
                 display_name: "Constitution Agent",
                 matrix_localpart: localpart,
                 status: :active
               })

      assert {:ok, _law} =
               Governance.create_law(%{
                 "slug" => "explain-reasoning-#{suffix}",
                 "name" => "Explain Reasoning",
                 "markdown_body" => """
                 # Explain Reasoning

                 Every agent response must explain why a decision matters to members.
                 """,
                 "law_kind" => "general",
                 "position" => 1
               })

      assert {:ok, snapshot} =
               Governance.publish_constitution_snapshot(%{"published_by_id" => agent.id})

      assert {:ok, _provider} =
               Settings.create_llm_provider_config(%{
                 "name" => "Local Constitution",
                 "slug" => "local-constitution-#{suffix}",
                 "provider" => "local",
                 "model" => "local-default",
                 "enabled" => true,
                 "is_default" => true
               })

      assert {:ok, response} =
               Client.generate_response(
                 agent_id: agent.id,
                 agent_slug: agent.slug,
                 user_input: "Give me a short answer",
                 context_text: "Conversation context",
                 trace_context: %{
                   run_id: "run-#{suffix}",
                   requested_by: "@member:localhost",
                   sender_mxid: "@member:localhost",
                   room_id: "!governance:localhost",
                   conversation_scope: "room",
                   constitution_snapshot_id: snapshot.id,
                   constitution_version: snapshot.version
                 }
               )

      assert response =~ "I received your request"

      [trace] = Agents.list_llm_traces(limit: 1)
      messages = Map.get(trace.request_payload, "messages", [])
      trace_context = Map.get(trace.request_payload, "trace_context", %{})

      assert trace_context["constitution_snapshot_id"] == snapshot.id
      assert trace_context["constitution_version"] == snapshot.version

      assert Enum.any?(messages, fn
               %{"role" => "system", "content" => content} ->
                 String.contains?(content, "Explain Reasoning")

               _ ->
                 false
             end)
    end
  end
end
