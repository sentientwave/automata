defmodule SentientwaveAutomataWeb.API.WorkflowController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.Orchestrator

  def create(conn, params) do
    payload = %{
      room_id: Map.get(params, "room_id", ""),
      objective: Map.get(params, "objective", ""),
      requested_by: Map.get(params, "requested_by", ""),
      edition: edition_param(Map.get(params, "edition"))
    }

    case Orchestrator.start_workflow(payload) do
      {:ok, workflow} ->
        conn
        |> put_status(:created)
        |> json(%{
          workflow_id: workflow.workflow_id,
          run_id: workflow.run_id,
          room_id: workflow.room_id,
          objective: workflow.objective,
          status: workflow.status,
          requested_by: workflow.requested_by,
          inserted_at: workflow.inserted_at
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  def index(conn, _params) do
    workflows =
      Orchestrator.list_workflows()
      |> Enum.map(fn wf ->
        %{
          workflow_id: wf.workflow_id,
          run_id: wf.run_id,
          room_id: wf.room_id,
          objective: wf.objective,
          status: wf.status,
          requested_by: wf.requested_by,
          inserted_at: wf.inserted_at
        }
      end)

    json(conn, %{data: workflows})
  end

  defp edition_param("enterprise"), do: :enterprise
  defp edition_param(_), do: :community
end
