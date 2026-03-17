defmodule SentientwaveAutomata.Agents.MentionDispatcher do
  @moduledoc """
  Persists mention events and starts one durable run per mentioned agent.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.{Durable, MentionRouter}
  require Logger

  @spec dispatch(map()) :: {:ok, map()} | {:error, term()}
  def dispatch(
        %{room_id: room_id, sender_mxid: sender_mxid, message_id: message_id, body: body} = attrs
      ) do
    with {:ok, mention} <- upsert_mention(attrs),
         targets when is_list(targets) <-
           MentionRouter.resolve_targets(body, room_id: room_id, sender_mxid: sender_mxid),
         {:ok, run_ids} <- start_runs(targets, mention, room_id, body, sender_mxid) do
      Logger.info(
        "mention_dispatch room=#{room_id} sender=#{sender_mxid} message_id=#{message_id} targets=#{length(targets)} runs=#{length(run_ids)}"
      )

      if run_ids == [] do
        {:error, :no_agent_mentioned}
      else
        {:ok, %{mention_id: mention.id, run_ids: run_ids, target_count: length(targets)}}
      end
    end
  end

  defp start_runs(targets, mention, room_id, body, sender_mxid) do
    result =
      Enum.reduce_while(targets, {:ok, []}, fn agent, {:ok, run_ids} ->
        attrs = %{
          agent_id: agent.id,
          mention_id: mention.id,
          room_id: room_id,
          trigger: :mention,
          requested_by: sender_mxid,
          input: %{body: body, sender_mxid: sender_mxid, mention_id: mention.id},
          metadata: %{agent_slug: agent.slug}
        }

        case Durable.start_run(attrs) do
          {:ok, run} ->
            {:cont, {:ok, [run.id | run_ids]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, run_ids} -> {:ok, Enum.reverse(run_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_mention(attrs) do
    case Agents.get_mention_by_message_id(attrs.message_id) do
      nil -> Agents.create_mention(attrs)
      mention -> {:ok, mention}
    end
  end
end
