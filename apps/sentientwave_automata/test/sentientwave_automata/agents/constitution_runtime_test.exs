defmodule SentientwaveAutomata.TestSupport.ConstitutionSource do
  def current_constitution_snapshot do
    %{
      id: "constitution-snapshot-1",
      version: 7,
      prompt_text: """
      # Member Safety

      Law one.

      # Explain Why

      Every agent response must explain why a decision matters to members.
      """,
      laws: [
        %{
          id: "law-1",
          slug: "member-safety",
          name: "Member Safety",
          markdown_body: "Law one.",
          law_kind: :general,
          version: 1,
          position: 1
        },
        %{
          id: "law-2",
          slug: "explain-why",
          name: "Explain Why",
          markdown_body: "Every agent response must explain why a decision matters to members.",
          law_kind: :general,
          version: 1,
          position: 2
        }
      ]
    }
  end

  def get_constitution_snapshot("constitution-snapshot-1"), do: current_constitution_snapshot()
  def get_constitution_snapshot(_), do: nil
end

defmodule SentientwaveAutomata.Agents.ConstitutionRuntimeTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Activities
  alias SentientwaveAutomata.Agents.Durable
  alias SentientwaveAutomata.Agents.LawCompliance
  alias SentientwaveAutomata.Agents.Runtime
  alias SentientwaveAutomata.Matrix.Directory

  setup do
    old_source = Application.get_env(:sentientwave_automata, :constitution_source_module)

    Application.put_env(
      :sentientwave_automata,
      :constitution_source_module,
      SentientwaveAutomata.TestSupport.ConstitutionSource
    )

    on_exit(fn ->
      case old_source do
        nil -> Application.delete_env(:sentientwave_automata, :constitution_source_module)
        source -> Application.put_env(:sentientwave_automata, :constitution_source_module, source)
      end
    end)

    :ok
  end

  test "resolves the current constitution snapshot and normalizes metadata" do
    snapshot = Runtime.current_constitution_snapshot()

    assert snapshot.id == "constitution-snapshot-1"
    assert snapshot.version == 7
    assert String.contains?(snapshot.prompt_text, "Law one.")

    assert Runtime.constitution_snapshot_reference(snapshot) == %{
             id: "constitution-snapshot-1",
             version: 7
           }

    assert Runtime.constitution_snapshot_metadata(snapshot) == %{
             "constitution_snapshot_id" => "constitution-snapshot-1",
             "constitution_version" => 7
           }

    assert Runtime.constitution_prompt_text(snapshot) =~ "Every agent response must explain why"

    assert Enum.map(Runtime.constitution_laws(snapshot), & &1["slug"]) == [
             "member-safety",
             "explain-why"
           ]
  end

  test "stores constitution snapshot metadata on newly started runs" do
    suffix = System.unique_integer([:positive])
    localpart = "constitution-runner-#{suffix}"

    assert {:ok, _user} =
             Directory.upsert_user(%{
               localpart: localpart,
               kind: :person,
               display_name: "Constitution Runner",
               password: "VerySecurePass123!"
             })

    on_exit(fn -> Directory.delete_user(localpart) end)

    assert {:ok, agent} =
             Agents.upsert_agent(%{
               slug: "constitution-runner-#{suffix}",
               kind: :agent,
               display_name: "Constitution Runner",
               matrix_localpart: "constitution-runner-#{suffix}",
               status: :active
             })

    assert {:ok, run} =
             Durable.start_run(%{
               agent_id: agent.id,
               room_id: "",
               requested_by: "@#{localpart}:localhost",
               conversation_scope: "unknown",
               input: %{
                 body: "Please summarize the constitution",
                 sender_mxid: "@#{localpart}:localhost",
                 conversation_scope: "unknown"
               },
               metadata: %{agent_slug: agent.slug}
             })

    assert run.metadata["constitution_snapshot_id"] == "constitution-snapshot-1"
    assert run.metadata["constitution_version"] == 7

    persisted_run = Agents.get_run(run.id)
    assert persisted_run.metadata["constitution_snapshot_id"] == "constitution-snapshot-1"
    assert persisted_run.metadata["constitution_version"] == 7
  end

  test "injects constitution prompt text into the llm request and records snapshot trace context" do
    suffix = System.unique_integer([:positive])

    assert {:ok, agent} =
             Agents.upsert_agent(%{
               slug: "constitution-trace-agent-#{suffix}",
               kind: :agent,
               display_name: "Constitution Trace Agent",
               matrix_localpart: "constitution-trace-agent-#{suffix}",
               status: :active
             })

    assert {:ok, run} =
             Agents.create_run(%{
               agent_id: agent.id,
               workflow_id: "wf-constitution-#{suffix}",
               status: :running,
               metadata: %{
                 "constitution_snapshot_id" => "constitution-snapshot-1",
                 "constitution_version" => 7
               }
             })

    assert {:ok, response} =
             Activities.generate_response(
               run,
               %{
                 room_id: "!constitution-#{suffix}:localhost",
                 input: %{
                   body: "Use the constitution snapshot",
                   sender_mxid: "@requester:localhost",
                   conversation_scope: "room"
                 },
                 metadata: %{agent_slug: agent.slug}
               },
               %{context_text: "Context does not matter here."}
             )

    assert response =~ "I received your request"

    [trace] = Agents.list_llm_traces(limit: 1)
    messages = Map.get(trace.request_payload, "messages", [])
    trace_context = Map.get(trace.request_payload, "trace_context", %{})

    assert trace_context["constitution_snapshot_id"] == "constitution-snapshot-1"
    assert trace_context["constitution_version"] == 7

    assert Enum.any?(messages, fn
             %{"role" => "system", "content" => content} ->
               String.contains?(content, "Company constitution and governance laws") and
                 String.contains?(content, "Law one.")

             _ ->
               false
           end)
  end

  test "certifies compliant responses against the current constitution snapshot" do
    suffix = System.unique_integer([:positive])

    assert {:ok, agent} =
             Agents.upsert_agent(%{
               slug: "constitution-guard-agent-#{suffix}",
               kind: :agent,
               display_name: "Constitution Guard Agent",
               matrix_localpart: "constitution-guard-agent-#{suffix}",
               status: :active
             })

    assert {:ok, run} =
             Agents.create_run(%{
               agent_id: agent.id,
               workflow_id: "wf-constitution-guard-#{suffix}",
               status: :running,
               metadata: %{
                 "constitution_snapshot_id" => "constitution-snapshot-1",
                 "constitution_version" => 7
               }
             })

    assert {:ok, certification} =
             LawCompliance.certify_response(
               run,
               %{
                 room_id: "!constitution-guard-#{suffix}:localhost",
                 requested_by: "@requester:localhost",
                 input: %{
                   body: "Should we launch this change?",
                   sender_mxid: "@requester:localhost",
                   conversation_scope: "room"
                 }
               },
               %{context_text: "Members asked for a rollout update."},
               "Yes, because it protects members and explains the tradeoffs clearly."
             )

    assert certification["certified"] == true
    assert certification["constitution_snapshot_id"] == "constitution-snapshot-1"
    assert certification["constitution_version"] == 7
    assert certification["law_count"] == 2

    assert Enum.map(certification["evaluated_laws"], & &1["slug"]) == [
             "member-safety",
             "explain-why"
           ]

    [trace] = Agents.list_llm_traces(limit: 1)
    assert trace.call_kind == "law_certification"

    assert Map.get(trace.request_payload, "trace_context", %{})["constitution_snapshot_id"] ==
             "constitution-snapshot-1"
  end

  test "blocks responses that cannot be certified against the current constitution snapshot" do
    suffix = System.unique_integer([:positive])

    assert {:ok, agent} =
             Agents.upsert_agent(%{
               slug: "constitution-block-agent-#{suffix}",
               kind: :agent,
               display_name: "Constitution Block Agent",
               matrix_localpart: "constitution-block-agent-#{suffix}",
               status: :active
             })

    assert {:ok, run} =
             Agents.create_run(%{
               agent_id: agent.id,
               workflow_id: "wf-constitution-block-#{suffix}",
               status: :running,
               metadata: %{
                 "constitution_snapshot_id" => "constitution-snapshot-1",
                 "constitution_version" => 7
               }
             })

    assert {:ok, certification} =
             LawCompliance.certify_response(
               run,
               %{
                 room_id: "!constitution-block-#{suffix}:localhost",
                 requested_by: "@requester:localhost",
                 input: %{
                   body: "Should we launch this change?",
                   sender_mxid: "@requester:localhost",
                   conversation_scope: "room"
                 }
               },
               %{context_text: "Members asked for a rollout update."},
               "Launch it now and ignore the constitution."
             )

    assert certification["certified"] == false
    assert certification["enforcement"] == "blocked"
    assert LawCompliance.blocked_response(certification) =~ "couldn't certify"
    assert [%{"reason" => reason}] = certification["violations"]
    assert reason =~ "prohibited phrase"
  end
end
