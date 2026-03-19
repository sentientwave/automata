defmodule SentientwaveAutomata.Agents.LLMTraceTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.LLM.Client
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Settings

  test "stores successful provider request and response traces with requester metadata" do
    suffix = System.unique_integer([:positive])
    localpart = "trace-user-#{suffix}"
    agent_localpart = "trace-agent-#{suffix}"

    assert {:ok, _user} =
             Directory.upsert_user(%{
               localpart: localpart,
               kind: :person,
               display_name: "Trace User",
               password: "VerySecurePass123!"
             })

    on_exit(fn -> Directory.delete_user(localpart) end)

    assert {:ok, agent} =
             Agents.upsert_agent(%{
               slug: agent_localpart,
               kind: :agent,
               display_name: "Trace Agent",
               matrix_localpart: agent_localpart,
               status: :active
             })

    assert {:ok, mention} =
             Agents.create_mention(%{
               room_id: "!dm-#{suffix}:localhost",
               sender_mxid: "@#{localpart}:localhost",
               message_id: "$msg-#{suffix}",
               body: "hello automata",
               status: :pending,
               metadata: %{
                 "remote_ip" => "10.20.30.40",
                 "conversation_scope" => "private_message"
               }
             })

    assert {:ok, run} =
             Agents.create_run(%{
               agent_id: agent.id,
               mention_id: mention.id,
               workflow_id: "wf-success-#{suffix}",
               status: :running,
               metadata: %{}
             })

    assert {:ok, _provider} =
             Settings.create_llm_provider_config(%{
               "name" => "Local Trace",
               "slug" => "local-trace-#{suffix}",
               "provider" => "local",
               "model" => "local-default",
               "enabled" => true,
               "is_default" => true
             })

    assert {:ok, response} =
             Client.generate_response(
               agent_id: agent.id,
               agent_slug: agent.slug,
               user_input: "Hello there",
               context_text: "",
               room_id: mention.room_id,
               trace_context: %{
                 run_id: run.id,
                 mention_id: mention.id,
                 requested_by: mention.sender_mxid,
                 sender_mxid: mention.sender_mxid,
                 room_id: mention.room_id,
                 conversation_scope: "private_message",
                 remote_ip: "10.20.30.40"
               }
             )

    assert response =~ "I received your request"

    [trace] = Agents.list_llm_traces(limit: 1)

    assert trace.agent_id == agent.id
    assert trace.run_id == run.id
    assert trace.mention_id == mention.id
    assert trace.provider == "local"
    assert trace.model == "local-default"
    assert trace.status == "ok"
    assert trace.requester_kind == "person"
    assert trace.requester_localpart == localpart
    assert trace.requester_mxid == "@#{localpart}:localhost"
    assert trace.room_id == mention.room_id
    assert trace.conversation_scope == "private_message"
    assert trace.remote_ip == "10.20.30.40"
    assert get_in(trace.request_payload, ["messages", Access.at(0), "role"]) == "system"
    assert get_in(trace.response_payload, ["content"]) == response
  end

  test "stores error traces when the provider returns an error" do
    suffix = System.unique_integer([:positive])
    localpart = "trace-agent-user-#{suffix}"
    agent_localpart = "trace-agent-target-#{suffix}"

    assert {:ok, _user} =
             Directory.upsert_user(%{
               localpart: localpart,
               kind: :agent,
               display_name: "Requesting Agent",
               password: "VerySecurePass123!"
             })

    on_exit(fn -> Directory.delete_user(localpart) end)

    assert {:ok, agent} =
             Agents.upsert_agent(%{
               slug: agent_localpart,
               kind: :agent,
               display_name: "Responder Agent",
               matrix_localpart: agent_localpart,
               status: :active
             })

    assert {:ok, provider} =
             Settings.create_llm_provider_config(%{
               "name" => "OpenAI Trace",
               "slug" => "openai-trace-#{suffix}",
               "provider" => "openai",
               "model" => "gpt-4o-mini",
               "api_token" => "",
               "enabled" => true,
               "is_default" => true
             })

    assert {:error, :missing_api_key} =
             Client.generate_response(
               agent_id: agent.id,
               agent_slug: agent.slug,
               user_input: "Need a reply",
               context_text: "",
               room_id: "!room-#{suffix}:localhost",
               trace_context: %{
                 requested_by: "@#{localpart}:localhost",
                 sender_mxid: "@#{localpart}:localhost",
                 room_id: "!room-#{suffix}:localhost",
                 conversation_scope: "room",
                 remote_ip: "127.0.0.1"
               }
             )

    [trace] = Agents.list_llm_traces(limit: 1)

    assert trace.provider_config_id == provider.id
    assert trace.provider == "openai"
    assert trace.model == "gpt-4o-mini"
    assert trace.status == "error"
    assert trace.requester_kind == "agent"
    assert trace.requester_localpart == localpart
    assert get_in(trace.error_payload, ["reason"]) == "missing_api_key"
    assert trace.response_payload == nil
  end
end
