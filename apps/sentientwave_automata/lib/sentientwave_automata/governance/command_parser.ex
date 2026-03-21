defmodule SentientwaveAutomata.Governance.CommandParser do
  @moduledoc """
  Parses governance commands from plain Matrix room messages.
  """

  @spec parse(map()) :: {:proposal, map()} | {:vote, map()} | :ignore | {:error, term()}
  def parse(%{} = event) do
    body = message_body(event)

    cond do
      body == "" ->
        :ignore

      vote_command?(body) ->
        parse_vote(body, event)

      proposal_command?(body) ->
        parse_proposal(body, event)

      true ->
        :ignore
    end
  end

  def parse(_event), do: :ignore

  defp parse_vote(body, event) do
    case Regex.run(~r/^\s*vote\s+(\S+)\s+(\S+)(?:\s+(.*))?$/is, body, capture: :all_but_first) do
      [reference, choice | rest] ->
        choice = normalize_vote_choice(choice)

        attrs =
          %{
            reference: String.trim(reference),
            choice: choice,
            reason: rest |> List.first() |> normalize_optional_text(),
            room_id: map_string(event, "room_id", map_atom(event, :room_id, "")),
            sender_mxid: map_string(event, "sender", map_atom(event, :sender_mxid, "")),
            message_id: map_string(event, "event_id", map_atom(event, :message_id, "")),
            raw_event: event,
            metadata: map_value(event, :metadata, map_value(event, "metadata", %{}))
          }

        case choice do
          :approve -> {:vote, attrs}
          :reject -> {:vote, attrs}
          :abstain -> {:vote, attrs}
          _ -> {:error, :invalid_vote_choice}
        end

      _ ->
        {:error, :invalid_vote_command}
    end
  end

  defp parse_proposal(body, event) do
    case Regex.run(
           ~r/^\s*(?:proposal|propose|law)\s+(\S+)(?:\s+(.*))?$/is,
           body,
           capture: :all_but_first
         ) do
      [action | rest] ->
        action = normalize_proposal_action(action)
        payload = List.first(rest) |> normalize_optional_text()

        case action do
          :create ->
            with {:ok, proposal} <- parse_payload(payload) do
              {:proposal, build_proposal_command(:create, nil, proposal, event)}
            end

          :amend ->
            with {:ok, {target_ref, proposal}} <- parse_targeted_payload(payload) do
              {:proposal, build_proposal_command(:amend, target_ref, proposal, event)}
            end

          :repeal ->
            with {:ok, {target_ref, proposal}} <- parse_targeted_payload(payload) do
              {:proposal, build_proposal_command(:repeal, target_ref, proposal, event)}
            end

          _ ->
            {:error, :invalid_proposal_action}
        end

      _ ->
        {:error, :invalid_proposal_command}
    end
  end

  defp build_proposal_command(proposal_type, target_ref, proposal_attrs, event) do
    %{
      proposal_type: proposal_type,
      target_ref: normalize_optional_text(target_ref),
      proposal: proposal_attrs,
      eligible_role_ids: normalize_id_list(Map.get(proposal_attrs, "eligible_role_ids", [])),
      room_id: map_string(event, "room_id", map_atom(event, :room_id, "")),
      sender_mxid: map_string(event, "sender", map_atom(event, :sender_mxid, "")),
      message_id: map_string(event, "event_id", map_atom(event, :message_id, "")),
      raw_event: event,
      metadata: map_value(event, :metadata, map_value(event, "metadata", %{}))
    }
  end

  defp parse_targeted_payload(payload) do
    payload = normalize_optional_text(payload)

    case payload do
      nil ->
        {:error, :invalid_targeted_proposal_payload}

      _ ->
        case Regex.run(~r/^\s*(\S+)(?:\s+(.*))?$/is, payload, capture: :all_but_first) do
          [target_ref, rest] ->
            with {:ok, parsed} <- parse_payload(normalize_optional_text(rest)) do
              {:ok, {String.trim(target_ref), parsed}}
            end

          [target_ref] ->
            {:ok, {String.trim(target_ref), %{}}}

          _ ->
            {:error, :invalid_targeted_proposal_payload}
        end
    end
  end

  defp parse_payload(""), do: {:ok, %{}}

  defp parse_payload(payload) when is_binary(payload) do
    trimmed = String.trim(payload)

    cond do
      trimmed == "" ->
        {:ok, %{}}

      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:ok, decoded} -> {:ok, %{"value" => decoded}}
          {:error, reason} -> {:error, {:invalid_json_payload, reason}}
        end

      true ->
        {:ok, parse_key_value_payload(trimmed)}
    end
  end

  defp parse_payload(_), do: {:error, :invalid_payload}

  defp parse_key_value_payload(text) do
    text
    |> Regex.split(~r/\s*\|\s*|\n+/u, trim: true)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] ->
          Map.put(acc, normalize_key(key), normalize_value(value))

        _ ->
          acc
      end
    end)
  end

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/u, "_")
    |> String.trim("_")
  end

  defp normalize_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> strip_quotes()
  end

  defp normalize_id_list(nil), do: []
  defp normalize_id_list([]), do: []

  defp normalize_id_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_id_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_id_list()
  end

  defp normalize_id_list(value), do: [value |> to_string() |> String.trim()]

  defp strip_quotes(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") and
          String.length(value) >= 2 ->
        value |> String.slice(1, String.length(value) - 2)

      String.starts_with?(value, "'") and String.ends_with?(value, "'") and
          String.length(value) >= 2 ->
        value |> String.slice(1, String.length(value) - 2)

      true ->
        value
    end
  end

  defp normalize_optional_text(nil), do: nil

  defp normalize_optional_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_vote_choice(choice) do
    case choice |> to_string() |> String.trim() |> String.downcase() do
      "approve" -> :approve
      "yes" -> :approve
      "reject" -> :reject
      "no" -> :reject
      "abstain" -> :abstain
      other -> other
    end
  end

  defp normalize_proposal_action(action) do
    case action |> to_string() |> String.trim() |> String.downcase() do
      "create" -> :create
      "amend" -> :amend
      "repeal" -> :repeal
      _ -> :invalid
    end
  end

  defp vote_command?(body), do: String.match?(body, ~r/^\s*vote\s+/i)
  defp proposal_command?(body), do: String.match?(body, ~r/^\s*(?:proposal|propose|law)\s+/i)

  defp message_body(event) do
    case Map.get(event, "body") || Map.get(event, :body) do
      nil ->
        event
        |> Map.get("content", %{})
        |> case do
          %{} = content -> Map.get(content, "body", "")
          _ -> ""
        end

      value ->
        value
    end
    |> to_string()
    |> String.trim()
  end

  defp map_string(map, key, default) do
    case Map.get(map, key, default) do
      ^default when is_binary(key) ->
        try do
          Map.get(map, String.to_existing_atom(key), default)
        rescue
          _ -> default
        end

      value ->
        value
    end
    |> to_string()
    |> String.trim()
  end

  defp map_atom(map, key, default) do
    Map.get(map, key, default)
  end

  defp map_value(map, key, default) when is_map(map) do
    case Map.get(map, key, default) do
      ^default when is_binary(key) ->
        try do
          Map.get(map, String.to_existing_atom(key), default)
        rescue
          _ -> default
        end

      ^default when is_atom(key) ->
        Map.get(map, Atom.to_string(key), default)

      value ->
        value
    end
  rescue
    _ -> default
  end

  defp map_value(_map, _key, default), do: default
end
