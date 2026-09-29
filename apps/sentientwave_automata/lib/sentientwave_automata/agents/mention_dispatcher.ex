defmodule SentientwaveAutomata.Agents.MentionDispatcher do
  @moduledoc """
  Persists mention events and starts one durable run per mentioned agent.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.{Durable, Mention, MentionRouter}
  alias SentientwaveAutomata.Adapters.Matrix.Synapse
  alias SentientwaveAutomata.Agents.Runtime
  alias SentientwaveAutomata.Matrix.SynapseAdmin
  alias SentientwaveAutomata.Repo

  require Logger

  @default_agent_agent_max_rounds_per_window 6
  @default_agent_agent_window_seconds 600

  @spec dispatch(map()) :: {:ok, map()} | {:error, term()}
  def dispatch(
        %{room_id: room_id, sender_mxid: sender_mxid, message_id: message_id, body: body} = attrs
      ) do
    # Truthful regardless of the autonomy flag: the explicit_only and
    # agent-conversation budget guards must apply to agent-to-agent chats
    # even with autonomy disabled, or two agents in a DM ping-pong forever.
    agent_sent? = MentionRouter.agent_sender?(sender_mxid)

    # Mention pills (Element @-pills) live in the raw event, not in the plain
    # body: the body only carries display text ("Andre Caldwell: hi").
    pill_localparts = MentionRouter.extract_pill_localparts(Map.get(attrs, :raw_event, %{}))

    # Agent-sent messages (agent-to-agent direct chats) are processed only
    # for the explicitly mentioned colleagues; everything else an agent posts
    # is a reply/announcement and must not cascade into new runs.
    resolve_opts =
      [
        room_id: room_id,
        sender_mxid: sender_mxid,
        pill_localparts: pill_localparts
      ] ++ if(agent_sent?, do: [explicit_only: true], else: [])

    with :ok <- enforce_agent_conversation_budget(agent_sent?, room_id),
         {:ok, mention, :new} <- upsert_mention(tag_agent_sender(attrs, agent_sent?)) do
      # Fetched once here and shared with the router (and the DM detection)
      # instead of letting every resolver path hit the homeserver again.
      members =
        case Synapse.joined_members(room_id) do
          {:ok, members} -> members
          _ -> []
        end

      resolve_opts = Keyword.put(resolve_opts, :joined_members, members)
      direct_room? = MentionRouter.direct_room?(members)

      {targets, fallback_dm} =
        case MentionRouter.resolve_targets(body, resolve_opts) do
          [] when not agent_sent? ->
            # Fresh direct rooms race the first sync: the counterparty agent
            # may be invited but not joined yet, so the room looks empty to
            # the router. Resolve the sole other participant (join, invite or
            # knock) and treat the message as addressed to that agent.
            {MentionRouter.resolve_direct_room_targets(resolve_opts), true}

          targets ->
            {targets, false}
        end

      # An agent may be addressed in a room it is not a member of (an explicit
      # @-mention in an invite-only room). Ensure membership before its run
      # posts, or the reply 403s as "not in room" (agents cannot self-join an
      # invite-only room without an invite).
      _ = ensure_target_membership(targets, members, room_id)

      {run_ids, failed} =
        start_runs(
          targets,
          mention,
          room_id,
          body,
          sender_mxid,
          agent_sent?,
          pill_localparts,
          direct_room? or fallback_dm
        )

      Logger.info(
        "mention_dispatch room=#{room_id} sender=#{sender_mxid} message_id=#{message_id} " <>
          "targets=#{length(targets)} runs=#{length(run_ids)} failed=#{length(failed)}"
      )

      cond do
        run_ids == [] and failed == [] ->
          _ = Runtime.mark_mention_status(mention, :ignored)

          if agent_sent? do
            {:error, :agent_message_no_mentioned_targets}
          else
            {:error, :no_agent_mentioned}
          end

        # Partial failure must not strand the un-started targets: the mention
        # row is persisted, so redelivery would return :already_processed and
        # nobody would ever retry them. Report the partial result instead.
        run_ids == [] ->
          _ = Runtime.mark_mention_status(mention, :failed)
          {:error, {:dispatch_failed, failed}}

        true ->
          _ = Runtime.mark_mention_status(mention, :completed)

          {:ok,
           %{
             mention_id: mention.id,
             run_ids: run_ids,
             target_count: length(targets),
             failed: Enum.reverse(failed)
           }}
      end
    else
      {:ok, _mention, :existing} -> {:error, :already_processed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tag_agent_sender(attrs, agent_sent?) do
    base = Map.get(attrs, :metadata, %{}) || %{}
    Map.put(attrs, :metadata, Map.put(base, "sender_is_agent", agent_sent?))
  end

  # Caps agent-to-agent conversation rounds per room so two agents cannot
  # chat endlessly: within a sliding window, only a limited number of
  # agent-sent messages are processed per room. The cap is a deterministic
  # safety net; the participation instructions keep exchanges short.
  defp enforce_agent_conversation_budget(false, _room_id), do: :ok

  defp enforce_agent_conversation_budget(true, room_id) do
    max_rounds = agent_agent_max_rounds_per_window()
    window_seconds = agent_agent_window_seconds()
    cutoff = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    count =
      from(m in Mention,
        where: m.room_id == ^room_id,
        where: m.inserted_at > ^cutoff,
        where: fragment("(?->>'sender_is_agent')::boolean", m.metadata),
        select: count(m.id)
      )
      |> Repo.one()

    if count >= max_rounds do
      Logger.info(
        "agent_conversation_cooldown room=#{room_id} rounds=#{count} max=#{max_rounds} window_s=#{window_seconds}"
      )

      {:error, :agent_conversation_cooldown}
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp agent_agent_max_rounds_per_window do
    System.get_env(
      "AUTOMATA_AGENT_AGENT_MAX_ROUNDS_PER_WINDOW",
      "#{@default_agent_agent_max_rounds_per_window}"
    )
    |> String.to_integer()
  rescue
    _ -> @default_agent_agent_max_rounds_per_window
  end

  defp agent_agent_window_seconds do
    System.get_env(
      "AUTOMATA_AGENT_AGENT_WINDOW_SECONDS",
      "#{@default_agent_agent_window_seconds}"
    )
    |> String.to_integer()
  rescue
    _ -> @default_agent_agent_window_seconds
  end

  # Invites (and joins) each targeted agent into the room when it is not
  # already a joined member. An agent addressed by mention in an invite-only
  # room cannot self-join without an invite, so its reply would otherwise
  # fail with M_FORBIDDEN. Idempotent: agents already in the room are skipped.
  defp ensure_target_membership(targets, joined_members, room_id) when is_list(targets) do
    joined_localparts =
      joined_members
      |> Enum.map(&mxid_localpart/1)
      |> MapSet.new()

    Enum.each(targets, fn agent ->
      localpart =
        agent
        |> Map.get(:matrix_localpart)
        |> case do
          lp when is_binary(lp) and lp != "" -> lp
          _ -> Map.get(agent, :slug, "") |> to_string()
        end

      if is_binary(localpart) and localpart != "" and
           not MapSet.member?(joined_localparts, localpart) do
        case SynapseAdmin.invite_localpart_to_room(localpart, room_id) do
          :ok ->
            Logger.info("mention_dispatch_ensured_membership agent=#{localpart} room=#{room_id}")

          {:error, reason} ->
            Logger.warning(
              "mention_dispatch_membership_failed agent=#{localpart} room=#{room_id} reason=#{inspect(reason)}"
            )
        end
      end
    end)
  end

  defp mxid_localpart(mxid) when is_binary(mxid) do
    mxid
    |> String.split("@", parts: 2)
    |> List.last()
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp mxid_localpart(_), do: ""

  defp start_runs(
         targets,
         mention,
         room_id,
         body,
         sender_mxid,
         agent_sent?,
         pill_localparts,
         directly_addressed?
       ) do
    {run_ids, failed} =
      do_start_runs(
        targets,
        mention,
        room_id,
        body,
        sender_mxid,
        agent_sent?,
        pill_localparts,
        directly_addressed?
      )

    {Enum.reverse(run_ids), Enum.reverse(failed)}
  end

  defp do_start_runs(
         targets,
         mention,
         room_id,
         body,
         sender_mxid,
         agent_sent?,
         pill_localparts,
         directly_addressed?
       ) do
    mentioned_localparts =
      (MentionRouter.extract_localparts(body) ++ pill_localparts)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    {started, failures} =
      Enum.reduce(targets, {[], []}, fn agent, {run_ids, failed} ->
        remote_ip = mention.metadata |> Map.get("remote_ip", "") |> to_string() |> String.trim()
        conversation_scope = mention.metadata |> Map.get("conversation_scope", "room")

        attrs = %{
          agent_id: agent.id,
          mention_id: mention.id,
          room_id: room_id,
          trigger: :mention,
          requested_by: sender_mxid,
          remote_ip: remote_ip,
          conversation_scope: conversation_scope,
          input: %{
            body: body,
            sender_mxid: sender_mxid,
            mention_id: mention.id,
            message_id: mention.message_id,
            remote_ip: remote_ip,
            conversation_scope: conversation_scope
          },
          metadata:
            mention.metadata
            |> Map.put_new("source", "mention_dispatch")
            |> Map.put("conversation_scope", conversation_scope)
            |> Map.put("agent_slug", agent.slug)
            |> Map.put("sender_is_agent", agent_sent?)
            |> Map.put("dispatch_target_count", length(targets))
            |> maybe_put_autonomy_flags()
            |> maybe_put_explicit_mention(agent, mentioned_localparts, directly_addressed?)
        }

        case Durable.start_run(attrs) do
          {:ok, run} ->
            {[run.id | run_ids], failed}

          {:error, reason} ->
            Logger.warning(
              "mention_run_start_failed agent_id=#{agent.id} mention_id=#{mention.id} reason=#{inspect(reason)}"
            )

            {run_ids, [{agent.id, inspect(reason)} | failed]}
        end
      end)

    {started, failures}
  end

  defp autonomy_mode? do
    System.get_env("AUTOMATA_ROOM_AUTONOMY_ENABLED", "false") in [
      "1",
      "true",
      "TRUE",
      "yes",
      "YES"
    ]
  end

  defp maybe_put_explicit_mention(metadata, agent, mentioned_localparts, directly_addressed?) do
    agent_localparts =
      [agent.slug, Map.get(agent, :matrix_localpart, "")]
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.downcase/1)

    mentioned? = Enum.any?(agent_localparts, &(&1 in mentioned_localparts))

    # A 1:1 room (or a fresh one whose only other participant is this agent)
    # addresses every message to the agent, even without a literal mention.
    addressed = mentioned? or directly_addressed?

    metadata
    |> Map.put("directly_addressed", addressed)
    |> maybe_put_true("explicitly_mentioned", addressed)
  end

  defp maybe_put_true(metadata, key, true), do: Map.put(metadata, key, true)

  defp maybe_put_true(metadata, _key, false), do: metadata

  defp maybe_put_autonomy_flags(metadata) when is_map(metadata) do
    if autonomy_mode?() do
      metadata
      |> Map.put("room_autonomy", true)
      |> Map.put("autonomy_max_rounds", autonomy_max_rounds())
    else
      metadata
    end
  end

  defp autonomy_max_rounds do
    case Integer.parse(System.get_env("AUTOMATA_ROOM_AUTONOMY_MAX_ROUNDS", "2")) do
      {n, _} when n >= 1 and n <= 5 -> n
      _ -> 2
    end
  end

  defp upsert_mention(attrs) do
    case Agents.get_mention_by_message_id(attrs.message_id) do
      nil ->
        case Agents.create_mention(attrs) do
          {:ok, mention} ->
            {:ok, mention, :new}

          # Lost a race with a concurrent delivery of the same event (sync
          # stream + mentions API): the unique index on message_id rejected
          # the insert, so treat the winner's row as the existing mention.
          {:error, %Ecto.Changeset{} = changeset} ->
            if Keyword.has_key?(changeset.errors, :message_id) do
              case Agents.get_mention_by_message_id(attrs.message_id) do
                nil -> {:error, changeset}
                mention -> {:ok, mention, :existing}
              end
            else
              {:error, changeset}
            end

          {:error, reason} ->
            {:error, reason}
        end

      mention ->
        # Already processed (e.g. a replayed timeline event): never start
        # duplicate runs for the same message.
        {:ok, mention, :existing}
    end
  end
end
