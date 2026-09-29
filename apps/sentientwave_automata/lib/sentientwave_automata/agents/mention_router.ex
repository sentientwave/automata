defmodule SentientwaveAutomata.Agents.MentionRouter do
  @moduledoc """
  Resolves agent mentions from Matrix messages.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Adapters.Matrix.Synapse

  @mention_regex ~r/@([a-z0-9._\-]+)(?::[a-z0-9.\-]+)?/i
  # R8: also matches "peter.parker?" at end-of-string (trailing punctuation,
  # no following whitespace required).
  @leading_name_regex ~r/^\s*([a-z0-9._\-]+)\s*[,:;!?-]*(?:\s+|$)/i
  @matrix_to_regex ~r{matrix\.to/\#/@([a-z0-9._\-]+)(?::[a-z0-9.\-]+)?}i

  @spec extract_localparts(String.t()) :: [String.t()]
  def extract_localparts(body) when is_binary(body) do
    tagged =
      @mention_regex
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.downcase/1)

    leading =
      case Regex.run(@leading_name_regex, body, capture: :all_but_first) do
        [name] -> [String.downcase(name)]
        _ -> []
      end

    (tagged ++ leading) |> Enum.uniq()
  end

  @doc """
  Extracts mention-pill localparts from a raw Matrix event.

  Clients (Element) put real mentions in `content.m.mentions.user_ids` and in
  `matrix.to` links inside `content.formatted_body`; the plain `body` only
  carries the display text (e.g. "Andre Caldwell: hi"), so pill mentions must
  be read from the raw event.
  """
  @spec extract_pill_localparts(map() | nil) :: [String.t()]
  def extract_pill_localparts(raw_event) when is_map(raw_event) do
    content = Map.get(raw_event, "content", %{})

    from_mentions =
      content
      |> Map.get("m.mentions", %{})
      |> Map.get("user_ids", [])
      |> Enum.map(&mxid_localpart/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)

    formatted = Map.get(content, "formatted_body", "")

    from_links =
      if is_binary(formatted) do
        # Clients HTML-escape formatted_body ("user&#58;example&#46;org"),
        # which would break the matrix.to pattern - decode before scanning.
        @matrix_to_regex
        |> Regex.scan(html_decode(formatted), capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&String.downcase/1)
      else
        []
      end

    (from_mentions ++ from_links)
    |> Enum.uniq()
  end

  def extract_pill_localparts(_), do: []

  defp html_decode(binary) when is_binary(binary) do
    binary
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#46;", ".")
    |> String.replace("&#58;", ":")
  end

  defp html_decode(other), do: other

  @spec resolve_targets(String.t(), keyword()) :: [SentientwaveAutomata.Agents.AgentProfile.t()]
  def resolve_targets(body, opts \\ []) when is_binary(body) do
    pill_localparts = Keyword.get(opts, :pill_localparts, [])

    explicit =
      (extract_localparts(body) ++ pill_localparts)
      |> Enum.uniq()
      |> Enum.map(&Agents.ensure_agent_from_directory/1)
      |> Enum.reject(&is_nil/1)

    cond do
      # Agent-sent messages only trigger explicitly mentioned colleagues;
      # this keeps agent conversations (public or DM) from cascading. In a
      # true two-person room, however, an unmentioned message is still a new
      # turn for the opposite member (including when both members are agents).
      # Deliberately independent of the autonomy flag: the ping-pong hazard
      # exists with autonomy off too.
      Keyword.get(opts, :explicit_only, false) ->
        if explicit == [], do: resolve_private_targets(opts), else: explicit

      autonomy_enabled?() and addressed_anyone?(body, explicit) ->
        # A message with a destination user addresses only that user:
        # the mentioned agents run and everyone else in the room ignores it
        # (they still see the message in their room history context).
        explicit

      explicit != [] ->
        explicit

      direct_room?(direct_room_members(opts)) ->
        # A 1:1 room: every message is addressed to the other participant,
        # with or without an explicit @mention. Deliberately independent of
        # the autonomy flag, like the explicit_only DM clause above.
        resolve_room_targets(opts)

      autonomy_enabled?() ->
        # No destination user: everyone in the room reads the message;
        # mentioned agents (none here) would get a respond bias.
        resolve_room_targets(opts)

      true ->
        resolve_private_targets(opts)
    end
  end

  @doc "True when the message addresses at least one user with an @mention."
  @spec mentioned_anyone?(String.t()) :: boolean()
  def mentioned_anyone?(body) when is_binary(body), do: Regex.match?(@mention_regex, body)

  @doc """
  True when the message addresses a specific user: either with an @mention, or
  with a leading localpart that resolves to an actual agent (e.g.
  "peter.parker, could you ..."). Leading words that do not match any agent
  ("Team, ..." or "Good morning ...") are not destinations.
  """
  @spec addressed_anyone?(String.t(), [SentientwaveAutomata.Agents.AgentProfile.t()]) :: boolean()
  # An unresolved leading name ("jane.doe, please ...") counts as addressing
  # only when it resolved to an actual agent (`explicit != []`). A bare @-token
  # counts too - but NOT when it is really part of an email/domain
  # ("user@example.com") or a well-known group tag ("@here", "@team"): those
  # must never silence the whole room.
  @group_mention_tags ~w(here room all channel team everyone)
  @bare_mention_regex ~r{(?<![\w.@])@([a-z0-9._\-]+)}i

  def addressed_anyone?(body, explicit) when is_binary(body) do
    explicit != [] or bare_user_mention?(body)
  end

  def addressed_anyone?(_body, _explicit), do: false

  defp bare_user_mention?(body) do
    @bare_mention_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(&(&1 not in @group_mention_tags))
  end

  @doc "True when the message sender is an agent (used to avoid agent self-triggering)."
  @spec agent_sender?(String.t()) :: boolean()
  def agent_sender?(sender_mxid) when is_binary(sender_mxid) do
    case sender_mxid |> mxid_localpart() |> Agents.ensure_agent_from_directory() do
      %{kind: :agent} -> true
      _ -> false
    end
  end

  def agent_sender?(_sender_mxid), do: false

  defp resolve_room_targets(opts) do
    room_id = opts |> Keyword.get(:room_id, "") |> to_string() |> String.trim()
    sender_mxid = opts |> Keyword.get(:sender_mxid, "") |> to_string() |> String.trim()

    with true <- room_id != "" and sender_mxid != "",
         {:ok, joined_members} <- joined_members(opts) do
      joined_members
      |> Enum.reject(&(&1 == sender_mxid))
      |> Enum.map(&mxid_localpart/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Agents.ensure_agent_from_directory/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.kind == :agent and &1.status == :active))
    else
      _ -> []
    end
  end

  defp autonomy_enabled? do
    System.get_env("AUTOMATA_ROOM_AUTONOMY_ENABLED", "false") in [
      "1",
      "true",
      "TRUE",
      "yes",
      "YES"
    ]
  end

  @doc """
  Fallback for fresh direct rooms: returns the sole other participant when the
  room has exactly one other participant (joined, invited, or knocking) and
  that participant is an active agent. Covers the window between room creation
  and the invited agent's first sync join, when `resolve_targets/2` sees an
  apparently empty room.
  """
  @spec resolve_direct_room_targets(keyword()) :: [SentientwaveAutomata.Agents.AgentProfile.t()]
  def resolve_direct_room_targets(opts) do
    room_id = opts |> Keyword.get(:room_id, "") |> to_string() |> String.trim()
    sender_mxid = opts |> Keyword.get(:sender_mxid, "") |> to_string() |> String.trim()

    with true <- room_id != "" and sender_mxid != "",
         {:ok, states} <- Synapse.room_member_states(room_id),
         [other] <-
           Map.keys(states)
           |> Enum.reject(&(&1 == sender_mxid or String.starts_with?(&1, "@_")))
           |> Enum.reject(&(mxid_localpart(&1) == "")) do
      case Agents.ensure_agent_from_directory(mxid_localpart(other)) do
        %{kind: :agent, status: :active} = agent -> [agent]
        _ -> []
      end
    else
      _ -> []
    end
  end

  defp resolve_private_targets(opts) do
    room_id = opts |> Keyword.get(:room_id, "") |> to_string() |> String.trim()
    sender_mxid = opts |> Keyword.get(:sender_mxid, "") |> to_string() |> String.trim()

    with true <- room_id != "" and sender_mxid != "",
         {:ok, joined_members} <- joined_members(opts),
         true <- direct_room?(joined_members) do
      joined_members
      |> Enum.reject(&(&1 == sender_mxid))
      |> Enum.map(&mxid_localpart/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Agents.ensure_agent_from_directory/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.kind == :agent and &1.status == :active))
    else
      _ -> []
    end
  end

  # Members used for direct-room detection. Reuses the pre-fetched member
  # list from opts when present (shared with `resolve_room_targets/1`) to
  # avoid a second homeserver round-trip.
  defp direct_room_members(opts) do
    case Keyword.get(opts, :joined_members) do
      members when is_list(members) ->
        members

      _ ->
        room_id = opts |> Keyword.get(:room_id, "") |> to_string() |> String.trim()

        if room_id == "" do
          []
        else
          case Synapse.joined_members(room_id) do
            {:ok, members} -> members
            _ -> []
          end
        end
    end
  end

  defp joined_members(opts) do
    room_id = opts |> Keyword.get(:room_id, "") |> to_string() |> String.trim()

    case Keyword.get(opts, :joined_members) do
      members when is_list(members) -> {:ok, members}
      _ when room_id != "" -> Synapse.joined_members(room_id)
      _ -> {:error, :invalid_room_id}
    end
  end

  @doc """
  True when `members` describes a direct (1:1) room: exactly two members once
  guest accounts (`@_...`) are excluded. Used to treat any message in a DM as
  addressed to the other participant.
  """
  @spec direct_room?([String.t()]) :: boolean()
  def direct_room?(members) when is_list(members) do
    members
    |> Enum.reject(&String.starts_with?(&1, "@_"))
    |> length()
    |> Kernel.==(2)
  end

  defp mxid_localpart("@" <> rest) do
    rest
    |> String.split(":", parts: 2)
    |> List.first()
    |> String.downcase()
  end

  defp mxid_localpart(_), do: ""
end
