defmodule SentientwaveAutomata.Agents.Tools.SendMatrixMessage do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  alias SentientwaveAutomata.Agents.Activities
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.SynapseAdmin

  @impl true
  def name, do: "send_matrix_message"

  @impl true
  def description do
    "Send a message over Matrix to an existing room (room_id) or to a colleague as a " <>
      "direct message (to = their localpart, e.g. \"john.smith\"). Use it to coordinate " <>
      "with other office members when a reply or information from them is required."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "room_id" => %{
          "type" => "string",
          "description" =>
            "Optional: the Matrix room ID to post into (e.g. !abc123:localhost). Use this to post into a room you are a member of."
        },
        "to" => %{
          "type" => "string",
          "description" =>
            "Optional: the localpart of the colleague to direct-message (e.g. \"jane.doe\"). The tool reuses or creates a DM room with that colleague."
        },
        "body" => %{
          "type" => "string",
          "description" =>
            "The message text. When direct-messaging a colleague, mention them with @localpart only when you need a reply from them."
        }
      },
      "required" => ["body"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    # Matrix chat operations are Temporal jobs too; they await completion by
    # default so conversations flow naturally. Pass "async": true to fire-and-forget.
    args =
      if Map.has_key?(args, "wait"), do: args, else: Map.put(args, "wait", true)

    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch(
      "send_matrix_message",
      args,
      opts,
      :send_failed
    )
  end

  @doc """
  Direct (non-Temporal) execution used by org-ops activities and tests.
  """
  def execute_direct(args, opts \\ []) when is_map(args) do
    agent_id = Keyword.get(opts, :agent_id)

    # Tolerate intuitive parameter names the model sometimes uses:
    # "message" == "body", "localpart"/"recipient" == "to".
    body = args |> Map.get("body", Map.get(args, "message", "")) |> to_string() |> String.trim()
    room_id = args |> Map.get("room_id", "") |> to_string() |> String.trim()

    target =
      args
      |> Map.get("to", Map.get(args, "localpart", Map.get(args, "recipient", "")))
      |> normalize_localpart()

    cond do
      body == "" ->
        {:error, :missing_body}

      is_nil(agent_id) ->
        {:error, :missing_agent_context}

      true ->
        with {:ok, resolved_target} <- resolve_recipient(target),
             {:ok, credentials} <- agent_credentials(agent_id),
             {:ok, resolved_room} <- resolve_room(credentials, room_id, resolved_target),
             final_body = ensure_mention(body, resolved_target),
             :ok <- matrix_adapter().post_message_as(resolved_room, final_body, credentials) do
          {:ok,
           %{
             "status" => "sent",
             "room_id" => resolved_room,
             "to" => resolved_target,
             "body" => final_body
           }}
        end
    end
  end

  defp resolve_room(credentials, room_id, target) do
    cond do
      # A named recipient always wins: messages addressed to a colleague go
      # to the direct-message room with that colleague, never to the room
      # the agent is currently working in.
      target != "" ->
        with {:ok, room} <- matrix_adapter().resolve_direct_room(credentials, target) do
          # The room reader account must be in every DM so messages flow
          # through the office poller, and the recipient must be joined for
          # two-way communication. Best-effort (room creation already
          # invited the recipient).
          participants =
            [target] ++
              if(safe_reader_localpart() in [nil, ""],
                do: [],
                else: [safe_reader_localpart()]
              )

          _ = safe_establish_membership(credentials, room, participants)

          {:ok, room}
        end

      room_id != "" ->
        {:ok, room_id}

      true ->
        {:error, :missing_room_or_recipient}
    end
  end

  defp ensure_mention(body, "") do
    body
  end

  defp ensure_mention(body, target) do
    mentioned? =
      ~r/@#{Regex.escape(target)}(?::[a-z0-9.\-]+)?/i
      |> Regex.match?(body)

    if mentioned?, do: body, else: "@#{target} #{body}"
  end

  @doc """
  Resolves a recipient name to a directory localpart. Accepts the exact
  localpart, the full display name, or a first name ("jane" -> "jane.doe").
  """
  def resolve_recipient(""), do: {:ok, ""}

  def resolve_recipient(input) when is_binary(input) do
    normalized = normalize_localpart(input)

    users = Directory.list_users()

    case Enum.find(users, &(&1.localpart == normalized)) do
      %{localpart: localpart} ->
        {:ok, localpart}

      nil ->
        found =
          Enum.find(users, fn user ->
            name = user.display_name |> to_string() |> String.downcase()
            first = name |> String.split() |> List.first() |> to_string()
            normalized == name or normalized == first
          end)

        case found do
          %{localpart: localpart} ->
            {:ok, localpart}

          nil ->
            # "firstname.lastname" fallback: try the segment before the dot
            # (e.g. "alex.smith" -> "alex").
            head = normalized |> String.split(".", parts: 2) |> List.first() |> to_string()

            case head != "" and Enum.find(users, &(&1.localpart == head)) do
              %{localpart: localpart} -> {:ok, localpart}
              _ -> {:error, {:unknown_recipient, normalized}}
            end
        end
    end
  end

  defp agent_credentials(agent_id) do
    case Activities.agent_post_credentials(agent_id) do
      %{} = credentials -> {:ok, credentials}
      nil -> {:error, :no_agent_wallet}
    end
  end

  defp safe_reader_localpart do
    matrix_adapter().reader_localpart()
  rescue
    _ -> ""
  end

  defp safe_establish_membership(credentials, room_id, participants) do
    creator = credentials |> Map.get("localpart") |> to_string() |> String.trim()

    if creator == "" do
      {:error, :missing_creator}
    else
      SynapseAdmin.establish_direct_room_membership(creator, room_id, participants)
    end
  rescue
    _ -> {:error, :membership_establishment_unavailable}
  end

  defp normalize_localpart(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split(":", parts: 2)
    |> List.first()
    |> String.downcase()
  end

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end
end
