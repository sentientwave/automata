defmodule SentientwaveAutomata.Adapters.Temporal.HttpBridge do
  @moduledoc """
  Minimal HTTP adapter for a Temporal bridge service.

  Expected bridge API:
  - POST /api/v1/workflows/start
  - POST /api/v1/workflows/:workflow_id/signal
  - POST /api/v1/agent-runs/start
  - POST /api/v1/agent-runs/:workflow_id/signal
  - GET /api/v1/agent-runs/:workflow_id
  """

  @behaviour SentientwaveAutomata.Adapters.Temporal.Behaviour

  @impl true
  def start_workflow(workflow_name, input, _opts) do
    payload = %{workflow_name: workflow_name, input: input}

    case post_json("/api/v1/workflows/start", payload) do
      {:ok, %{"workflow_id" => workflow_id, "run_id" => run_id, "status" => status}} ->
        {:ok, %{workflow_id: workflow_id, run_id: run_id, status: to_atom_status(status)}}

      {:ok, body} ->
        {:error, {:unexpected_bridge_payload, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def signal_workflow(workflow_id, signal, payload) do
    case post_json("/api/v1/workflows/#{workflow_id}/signal", %{signal: signal, payload: payload}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def start_agent_run(input) do
    case post_json("/api/v1/agent-runs/start", %{input: input}) do
      {:ok, %{"workflow_id" => workflow_id, "run_id" => run_id, "status" => status}} ->
        {:ok, %{workflow_id: workflow_id, run_id: run_id, status: to_atom_status(status)}}

      {:ok, body} ->
        {:error, {:unexpected_bridge_payload, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def signal_agent_run(workflow_id, payload) do
    case post_json("/api/v1/agent-runs/#{workflow_id}/signal", %{payload: payload}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def query_agent_run(workflow_id), do: get_json("/api/v1/agent-runs/#{workflow_id}")

  defp post_json(path, payload) do
    url = bridge_url() <> path
    body = Jason.encode!(payload)
    headers = [{~c"content-type", ~c"application/json"}]

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", body},
           [],
           []
         ) do
      {:ok, {{_, status_code, _}, _response_headers, response_body}}
      when status_code in 200..299 ->
        Jason.decode(to_string(response_body))

      {:ok, {{_, status_code, _}, _response_headers, response_body}} ->
        {:error, {:http_error, status_code, to_string(response_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_json(path) do
    url = bridge_url() <> path

    case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
      {:ok, {{_, status_code, _}, _response_headers, response_body}}
      when status_code in 200..299 ->
        Jason.decode(to_string(response_body))

      {:ok, {{_, status_code, _}, _response_headers, response_body}} ->
        {:error, {:http_error, status_code, to_string(response_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bridge_url do
    Application.get_env(:sentientwave_automata, :temporal_bridge_url, "http://localhost:8099")
  end

  defp to_atom_status(status) when is_atom(status), do: status

  defp to_atom_status(status) when is_binary(status) do
    case status do
      "running" -> :running
      "completed" -> :completed
      "failed" -> :failed
      "cancelled" -> :cancelled
      _ -> :running
    end
  end

  defp to_atom_status(_), do: :running
end
