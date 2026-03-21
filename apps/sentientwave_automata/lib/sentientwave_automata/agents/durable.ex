defmodule SentientwaveAutomata.Agents.Durable do
  @moduledoc """
  Durable execution facade for agent runs.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Runtime
  alias SentientwaveAutomata.Agents.Run
  alias SentientwaveAutomata.Agents.Workflow
  require Logger

  @spec start_run(map()) :: {:ok, Run.t()} | {:error, term()}
  def start_run(%{agent_id: agent_id} = attrs) do
    constitution_metadata =
      Runtime.constitution_snapshot_metadata(Runtime.current_constitution_snapshot())

    run_metadata = Map.merge(Map.get(attrs, :metadata, %{}), constitution_metadata)
    attrs = Map.merge(attrs, constitution_metadata)

    with {:ok, temporal} <- temporal_adapter().start_agent_run(attrs),
         {:ok, run} <-
           Agents.create_run(%{
             agent_id: agent_id,
             mention_id: Map.get(attrs, :mention_id),
             workflow_id: temporal.workflow_id,
             temporal_run_id: temporal.run_id,
             status: :running,
             metadata: run_metadata
           }) do
      finalize_run_async(run, attrs)
      {:ok, run}
    end
  end

  @spec signal_run(String.t(), map()) :: :ok | {:error, term()}
  def signal_run(workflow_id, payload) do
    temporal_adapter().signal_agent_run(workflow_id, payload)
  end

  @spec query_run(String.t()) :: {:ok, map()} | {:error, term()}
  def query_run(workflow_id), do: temporal_adapter().query_agent_run(workflow_id)

  defp finalize_run_async(%Run{} = run, attrs) do
    Task.start(fn ->
      room_id = Map.get(attrs, :room_id, "")

      typing_pid =
        start_typing_heartbeat(room_id, %{run_id: run.id, workflow_id: run.workflow_id})

      try do
        try do
          case Workflow.execute(run, attrs) do
            {:ok, %{response: response, context: context}} ->
              clean_response = to_plain_text(response)

              _ =
                Agents.update_run(run, %{
                  status: :succeeded,
                  result: %{
                    response: clean_response,
                    context: %{
                      total_items: get_in(context, [:stats, :total_items]),
                      total_chars: get_in(context, [:stats, :total_chars]),
                      compaction: Map.get(context, :compaction, %{})
                    }
                  }
                })

            {:error, reason} ->
              Logger.warning(
                "durable_run workflow_failed run_id=#{run.id} workflow_id=#{run.workflow_id} reason=#{inspect(reason)}"
              )

              _ = Agents.update_run(run, %{status: :failed, error: %{reason: inspect(reason)}})
          end
        rescue
          error ->
            Logger.error(
              "durable_run workflow_exception run_id=#{run.id} workflow_id=#{run.workflow_id} error=#{Exception.format(:error, error, __STACKTRACE__)}"
            )

            _ =
              Agents.update_run(run, %{
                status: :failed,
                error: %{reason: Exception.message(error)}
              })
        end
      after
        stop_typing_heartbeat(typing_pid)
        _ = set_typing(room_id, false, %{run_id: run.id, workflow_id: run.workflow_id})
      end
    end)
  end

  defp to_plain_text(text) when is_binary(text) do
    text
    |> String.replace(~r/```[\s\S]*?```/u, "")
    |> String.replace(~r/`([^`]*)`/u, "\\1")
    |> String.replace(~r/\*\*([^*]+)\*\*/u, "\\1")
    |> String.replace(~r/\*([^*]+)\*/u, "\\1")
    |> String.replace(~r/^\#{1,6}\s+/um, "")
    |> String.replace(~r/^\s*[-*+]\s+/um, "")
    |> String.replace(~r/^\s*\d+\.\s+/um, "")
    |> String.replace(~r/\[([^\]]+)\]\(([^)]+)\)/u, "\\1 (\\2)")
    |> String.replace(~r/<[^>]+>/u, "")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end

  defp temporal_adapter do
    Application.get_env(
      :sentientwave_automata,
      :temporal_adapter,
      SentientwaveAutomata.Adapters.Temporal.Local
    )
  end

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end

  defp set_typing(room_id, typing, metadata) when is_binary(room_id) and room_id != "" do
    case matrix_adapter().set_typing(room_id, typing, typing_timeout_ms(), metadata) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "durable_run typing_failed room=#{room_id} typing=#{typing} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp set_typing(_room_id, _typing, _metadata), do: :ok

  defp start_typing_heartbeat(room_id, metadata) when is_binary(room_id) and room_id != "" do
    parent = self()

    spawn_link(fn ->
      typing_loop(parent, room_id, metadata, typing_interval_ms())
    end)
  end

  defp start_typing_heartbeat(_room_id, _metadata), do: nil

  defp stop_typing_heartbeat(nil), do: :ok

  defp stop_typing_heartbeat(pid) when is_pid(pid) do
    ref = make_ref()
    send(pid, {:stop, self(), ref})

    receive do
      {:stopped, ^ref} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp typing_loop(parent, room_id, metadata, interval_ms) do
    _ = set_typing(room_id, true, metadata)

    receive do
      {:stop, caller, ref} ->
        send(caller, {:stopped, ref})
        :ok
    after
      interval_ms ->
        if Process.alive?(parent) do
          typing_loop(parent, room_id, metadata, interval_ms)
        else
          :ok
        end
    end
  end

  defp typing_interval_ms do
    timeout = typing_timeout_ms()
    max(div(timeout, 2), 1_000)
  end

  defp typing_timeout_ms do
    System.get_env("MATRIX_TYPING_TIMEOUT_MS", "12000")
    |> String.to_integer()
  rescue
    _ -> 12_000
  end
end
