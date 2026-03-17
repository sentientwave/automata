defmodule SentientwaveAutomataWeb.API.AgentRunsController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Durable

  def index(conn, _params) do
    runs =
      Agents.list_runs(limit: 100)
      |> Enum.map(fn run ->
        %{
          id: run.id,
          workflow_id: run.workflow_id,
          temporal_run_id: run.temporal_run_id,
          status: run.status,
          agent_id: run.agent_id,
          mention_id: run.mention_id,
          inserted_at: run.inserted_at,
          updated_at: run.updated_at
        }
      end)

    json(conn, %{data: runs})
  end

  def show(conn, %{"id" => id}) do
    case Agents.get_run(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: :not_found})

      run ->
        status =
          case Durable.query_run(run.workflow_id) do
            {:ok, payload} -> payload
            {:error, reason} -> %{error: reason}
          end

        json(conn, %{
          data: %{
            id: run.id,
            workflow_id: run.workflow_id,
            temporal_run_id: run.temporal_run_id,
            status: run.status,
            temporal_status: status,
            result: run.result,
            error: run.error,
            metadata: run.metadata
          }
        })
    end
  end
end
