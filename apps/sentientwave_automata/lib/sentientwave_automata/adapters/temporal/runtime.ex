defmodule SentientwaveAutomata.Adapters.Temporal.Runtime do
  @moduledoc """
  Real Temporal adapter backed by the Elixir Temporal SDK.
  """

  @behaviour SentientwaveAutomata.Adapters.Temporal.Behaviour

  alias SentientwaveAutomata.Temporal

  @workflow_map %{
    "conversation_workflow" => SentientwaveAutomata.Orchestration.ConversationWorkflow,
    "governance_proposal_workflow" => SentientwaveAutomata.Governance.ProposalWorkflow,
    "scheduled_task_workflow" => SentientwaveAutomata.Agents.ScheduledTaskWorkflow
  }

  @impl true
  def start_workflow(workflow_name, input, opts \\ []) when is_binary(workflow_name) do
    with {:ok, workflow_module} <- workflow_module(workflow_name),
         {:ok, response} <- start_temporal_workflow(workflow_module, input, opts) do
      {:ok, format_start_response(response)}
    end
  end

  @impl true
  def signal_workflow(workflow_id, signal, payload)
      when is_binary(workflow_id) and is_binary(signal) and is_map(payload) do
    case TemporalSdk.signal_workflow(
           Temporal.cluster(),
           Temporal.workflow_execution(workflow_id),
           signal,
           namespace: Temporal.namespace(),
           input: [payload]
         ) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @impl true
  def query_workflow(workflow_id) when is_binary(workflow_id) do
    case TemporalSdk.get_workflow_state(
           Temporal.cluster(),
           Temporal.workflow_execution(workflow_id),
           namespace: Temporal.namespace()
         ) do
      {:ok, status} -> {:ok, %{workflow_id: workflow_id, status: status, source: :temporal_sdk}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @impl true
  def start_agent_run(input) when is_map(input) do
    with {:ok, response} <-
           start_temporal_workflow(SentientwaveAutomata.Agents.Workflow, input, []) do
      {:ok, format_start_response(response)}
    end
  end

  @impl true
  def signal_agent_run(workflow_id, payload) when is_binary(workflow_id) and is_map(payload) do
    signal_workflow(workflow_id, "agent_signal", payload)
  end

  @impl true
  def query_agent_run(workflow_id), do: query_workflow(workflow_id)

  defp start_temporal_workflow(workflow_module, input, opts) when is_atom(workflow_module) do
    workflow_id =
      Keyword.get(opts, :workflow_id) ||
        Map.get(input, :workflow_id) ||
        Map.get(input, "workflow_id") ||
        Temporal.generated_workflow_id(to_string(workflow_module))

    # `opentelemetry: false` — the SDK defaults it to `true` in production builds
    # and injects a traceparent into the workflow start header. With only
    # `opentelemetry_api` present (no OpenTelemetry SDK), the no-op tracer's
    # non-recording span makes temporal_sdk 0.2.20 crash the workflow task
    # executor at init with `{:badmatch, false}` (`true = otel_span:add_events/2`).
    temporal_opts = [
      namespace: Temporal.namespace(),
      workflow_id: workflow_id,
      input: [input],
      opentelemetry: false
    ]

    case TemporalSdk.start_workflow(
           Temporal.cluster(),
           Temporal.workflow_task_queue(),
           workflow_module,
           temporal_opts
         ) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp workflow_module(workflow_name) do
    case Map.fetch(@workflow_map, workflow_name) do
      {:ok, workflow_module} -> {:ok, workflow_module}
      :error -> {:error, {:unsupported_workflow, workflow_name}}
    end
  end

  defp format_start_response(%{workflow_execution: %{workflow_id: workflow_id, run_id: run_id}}) do
    %{workflow_id: workflow_id, run_id: run_id, status: :running}
  end
end
