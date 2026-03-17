defmodule SentientwaveAutomata.Agents.MentionRouter do
  @moduledoc """
  Resolves agent mentions from Matrix messages.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Adapters.Matrix.Synapse

  @mention_regex ~r/@([a-z0-9._\-]+)(?::[a-z0-9.\-]+)?/i
  @leading_name_regex ~r/^\s*([a-z0-9._\-]+)\s*[:,-]?\s+/i

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

  @spec resolve_targets(String.t(), keyword()) :: [SentientwaveAutomata.Agents.AgentProfile.t()]
  def resolve_targets(body, opts \\ []) when is_binary(body) do
    explicit =
      body
      |> extract_localparts()
      |> Enum.map(&Agents.ensure_agent_from_directory/1)
      |> Enum.reject(&is_nil/1)

    if explicit != [] do
      explicit
    else
      resolve_private_targets(opts)
    end
  end

  defp resolve_private_targets(opts) do
    room_id = opts |> Keyword.get(:room_id, "") |> to_string() |> String.trim()
    sender_mxid = opts |> Keyword.get(:sender_mxid, "") |> to_string() |> String.trim()

    with true <- room_id != "" and sender_mxid != "",
         {:ok, joined_members} <- Synapse.joined_members(room_id),
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

  defp direct_room?(members) when is_list(members) do
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
