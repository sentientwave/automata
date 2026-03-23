defmodule SentientwaveAutomata.Orchestration.Activities do
  @moduledoc """
  Temporal activity entrypoint for generic conversation workflows.
  """

  use TemporalSdk.Activity

  alias SentientwaveAutomata.Orchestration.Workflow
  alias SentientwaveAutomata.Repo
  alias SentientwaveAutomata.Temporal

  @impl true
  def execute(
        _context,
        [%{"step" => "post_started_message", "workflow_id" => workflow_id, "attrs" => attrs}]
      ) do
    room_id = fetch_value(attrs, "room_id")
    objective = fetch_value(attrs, "objective")
    requested_by = fetch_value(attrs, "requested_by")

    if room_id in [nil, ""] do
      [%{"posted" => false}]
    else
      case matrix_adapter().post_message(room_id, "Workflow started: #{objective}", %{
             "workflow_id" => workflow_id,
             "requested_by" => requested_by,
             "kind" => "conversation_workflow_started"
           }) do
        :ok ->
          [%{"posted" => true, "room_id" => room_id}]

        {:error, reason} ->
          if permanent_post_error?(reason) do
            [
              %{
                "posted" => false,
                "room_id" => room_id,
                "permanent_error" => true,
                "error" => normalize_json_map(reason)
              }
            ]
          else
            raise "failed to post started message: #{inspect(reason)}"
          end
      end
    end
  end

  def execute(
        _context,
        [
          %{
            "step" => "mark_status",
            "workflow_id" => workflow_id,
            "status" => status
          } = payload
        ]
      ) do
    case Repo.get_by(Workflow, workflow_id: workflow_id) do
      %Workflow{} = workflow ->
        attrs = %{
          status: normalize_status(status),
          result: normalize_json_map(Map.get(payload, "result", %{})),
          error: normalize_json_map(Map.get(payload, "error", %{}))
        }

        case workflow |> Workflow.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            [
              %{
                "workflow_id" => updated.workflow_id,
                "status" => Atom.to_string(updated.status)
              }
            ]

          {:error, reason} ->
            raise "failed to mark orchestration workflow status: #{inspect(reason)}"
        end

      nil ->
        fail_non_retryable(
          "orchestration.workflow.not_found",
          "workflow not found: #{workflow_id}"
        )
    end
  end

  def execute(context, [%{} = payload]) do
    normalized_payload = Temporal.stringify_keys(payload)

    if normalized_payload == payload do
      fail_non_retryable(
        "orchestration.workflow.unsupported_step",
        "unsupported orchestration activity step: #{inspect(payload)}"
      )
    else
      execute(context, [normalized_payload])
    end
  end

  def execute(_context, [payload]) do
    fail_non_retryable(
      "orchestration.workflow.unsupported_step",
      "unsupported orchestration activity step: #{inspect(payload)}"
    )
  end

  defp fetch_value(map, key) when is_map(map) do
    atom_key =
      case key do
        "room_id" -> :room_id
        "objective" -> :objective
        "requested_by" -> :requested_by
        _ -> nil
      end

    Map.get(map, key) || (atom_key && Map.get(map, atom_key))
  end

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case String.trim(status) do
      "running" -> :running
      "succeeded" -> :succeeded
      "failed" -> :failed
      "cancelled" -> :cancelled
      _ -> :running
    end
  end

  defp permanent_post_error?(:invalid_room_id), do: true
  defp permanent_post_error?(:send_unauthorized_after_refresh), do: true

  defp permanent_post_error?({:send_http_error, status, _body})
       when status in [400, 403, 404],
       do: true

  defp permanent_post_error?(_reason), do: false

  defp normalize_json_map(nil), do: %{}
  defp normalize_json_map(%_{} = struct), do: %{"value" => inspect(struct)}
  defp normalize_json_map(%{} = map), do: Temporal.stringify_keys(map)

  defp normalize_json_map(tuple) when is_tuple(tuple),
    do: %{"items" => tuple |> Tuple.to_list() |> Enum.map(&normalize_json_value/1)}

  defp normalize_json_map([value]), do: normalize_json_map(value)

  defp normalize_json_map(list) when is_list(list) do
    %{"items" => Enum.map(list, &normalize_json_value/1)}
  end

  defp normalize_json_map(value) do
    %{"value" => normalize_json_value(value)}
  end

  defp normalize_json_value(%_{} = struct), do: inspect(struct)
  defp normalize_json_value(%{} = map), do: Temporal.stringify_keys(map)

  defp normalize_json_value(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&normalize_json_value/1)

  defp normalize_json_value(list) when is_list(list), do: Enum.map(list, &normalize_json_value/1)
  defp normalize_json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_json_value(value) when is_binary(value), do: value
  defp normalize_json_value(value) when is_boolean(value), do: value
  defp normalize_json_value(value) when is_integer(value), do: value
  defp normalize_json_value(value) when is_float(value), do: value
  defp normalize_json_value(nil), do: nil
  defp normalize_json_value(value), do: inspect(value)

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end

  defp fail_non_retryable(type, message) do
    fail(message: message, type: type, non_retryable: true)
  end
end
