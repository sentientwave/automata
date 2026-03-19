defmodule SentientwaveAutomata.Agents.LLM.TraceRecorder do
  @moduledoc """
  Persists normalized traces for every provider call without coupling storage to providers.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Matrix.Directory
  require Logger

  @spec record_completion(map(), (-> {:ok, String.t()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def record_completion(call_meta, fun) when is_map(call_meta) and is_function(fun, 0) do
    requested_at = DateTime.utc_now()

    try do
      result = fun.()
      completed_at = DateTime.utc_now()
      persist_trace(call_meta, result, requested_at, completed_at)
      result
    rescue
      error ->
        completed_at = DateTime.utc_now()

        persist_trace(
          call_meta,
          {:error,
           %{
             kind: "exception",
             message: Exception.message(error),
             detail: Exception.format(:error, error, __STACKTRACE__)
           }},
          requested_at,
          completed_at
        )

        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        completed_at = DateTime.utc_now()

        persist_trace(
          call_meta,
          {:error, %{kind: Atom.to_string(kind), reason: normalize_value(reason)}},
          requested_at,
          completed_at
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp persist_trace(call_meta, result, requested_at, completed_at) do
    attrs = trace_attrs(call_meta, result, requested_at, completed_at)

    case Agents.create_llm_trace(attrs) do
      {:ok, _trace} ->
        :ok

      {:error, changeset} ->
        Logger.warning("llm_trace_persist_failed errors=#{inspect(changeset.errors)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("llm_trace_persist_failed error=#{Exception.message(error)}")
      :ok
  end

  defp trace_attrs(call_meta, result, requested_at, completed_at) do
    requester = resolve_requester(Map.get(call_meta, :trace_context, %{}))

    %{
      agent_id: present(Map.get(call_meta, :agent_id)),
      run_id: present(get_in(call_meta, [:trace_context, :run_id])),
      mention_id: present(get_in(call_meta, [:trace_context, :mention_id])),
      provider_config_id: present(Map.get(call_meta, :provider_config_id)),
      provider: to_string(Map.get(call_meta, :provider, "")),
      model: to_string(Map.get(call_meta, :model, "")),
      call_kind: normalize_call_kind(Map.get(call_meta, :call_kind)),
      sequence_index: normalize_sequence_index(Map.get(call_meta, :sequence_index)),
      status: result_status(result),
      requester_id: Map.get(requester, :id),
      requester_kind: Map.get(requester, :kind),
      requester_localpart: Map.get(requester, :localpart),
      requester_mxid: Map.get(requester, :mxid),
      requester_display_name: Map.get(requester, :display_name),
      room_id: present(get_in(call_meta, [:trace_context, :room_id])),
      conversation_scope: normalize_conversation_scope(call_meta),
      remote_ip: present(get_in(call_meta, [:trace_context, :remote_ip])),
      request_payload: build_request_payload(call_meta),
      response_payload: build_response_payload(result),
      error_payload: build_error_payload(result),
      requested_at: requested_at,
      completed_at: completed_at
    }
  end

  defp resolve_requester(trace_context) when is_map(trace_context) do
    requested_by =
      Map.get(trace_context, :sender_mxid) ||
        Map.get(trace_context, :requested_by) ||
        Map.get(trace_context, "sender_mxid") ||
        Map.get(trace_context, "requested_by")

    localpart = requested_by |> normalize_localpart() |> present()

    case localpart && Directory.get_user(localpart) do
      %{id: id, kind: kind, localpart: user_localpart, display_name: display_name} ->
        %{
          id: id,
          kind: Atom.to_string(kind),
          localpart: user_localpart,
          mxid: normalize_mxid(requested_by, user_localpart),
          display_name: display_name
        }

      _ ->
        %{
          id: localpart || present(to_string_safe(requested_by)),
          kind: infer_requester_kind(requested_by),
          localpart: localpart,
          mxid: normalize_mxid(requested_by, localpart),
          display_name: localpart || present(to_string_safe(requested_by))
        }
    end
  end

  defp resolve_requester(_), do: %{}

  defp build_request_payload(call_meta) do
    %{
      "messages" => Enum.map(Map.get(call_meta, :messages, []), &normalize_value/1),
      "provider" => to_string(Map.get(call_meta, :provider, "")),
      "model" => to_string(Map.get(call_meta, :model, "")),
      "call_kind" => normalize_call_kind(Map.get(call_meta, :call_kind)),
      "sequence_index" => normalize_sequence_index(Map.get(call_meta, :sequence_index)),
      "base_url" => present(Map.get(call_meta, :base_url)),
      "timeout_seconds" => Map.get(call_meta, :timeout_seconds),
      "trace_context" => normalize_trace_context(Map.get(call_meta, :trace_context, %{}))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp build_response_payload({:ok, text}) when is_binary(text) do
    %{"content" => text, "content_length" => String.length(text)}
  end

  defp build_response_payload(_), do: nil

  defp build_error_payload({:error, reason}) do
    %{"reason" => normalize_value(reason)}
  end

  defp build_error_payload(_), do: nil

  defp result_status({:ok, _}), do: "ok"
  defp result_status(_), do: "error"

  defp normalize_trace_context(trace_context) when is_map(trace_context) do
    trace_context
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_value(value)} end)
    |> Map.new()
  end

  defp normalize_trace_context(_), do: %{}

  defp normalize_call_kind(nil), do: "response"

  defp normalize_call_kind(value),
    do: value |> to_string() |> String.trim() |> default_to("response")

  defp normalize_sequence_index(value) when is_integer(value) and value >= 0, do: value
  defp normalize_sequence_index(_), do: 0

  defp normalize_conversation_scope(call_meta) do
    value =
      get_in(call_meta, [:trace_context, :conversation_scope]) ||
        get_in(call_meta, [:trace_context, "conversation_scope"])

    cond do
      value in [:private_message, "private_message", "dm", "direct"] -> "private_message"
      value in [:room, "room"] -> "room"
      present(get_in(call_meta, [:trace_context, :room_id])) -> "room"
      true -> "unknown"
    end
  end

  defp normalize_mxid(value, localpart) do
    cond do
      is_binary(value) and String.starts_with?(String.trim(value), "@") ->
        String.trim(value)

      is_binary(localpart) and localpart != "" ->
        "@#{localpart}:#{System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")}"

      true ->
        nil
    end
  end

  defp normalize_localpart(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split(":", parts: 2)
    |> List.first()
    |> default_to(nil)
  end

  defp normalize_localpart(_), do: nil

  defp infer_requester_kind(value) when is_binary(value) do
    localpart = normalize_localpart(value)

    cond do
      is_nil(localpart) -> "unknown"
      String.starts_with?(localpart, "agent") -> "agent"
      true -> "unknown"
    end
  end

  defp infer_requester_kind(_), do: "unknown"

  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(value) when is_integer(value), do: value
  defp normalize_value(value) when is_float(value), do: value
  defp normalize_value(nil), do: nil

  defp normalize_value(value) when is_atom(value) do
    Atom.to_string(value)
  end

  defp normalize_value(value) when is_list(value) do
    Enum.map(value, &normalize_value/1)
  end

  defp normalize_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, entry} -> {to_string(key), normalize_value(entry)} end)
    |> Map.new()
  end

  defp normalize_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize_value/1)
  end

  defp normalize_value(value), do: inspect(value)

  defp present(nil), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(value), do: value

  defp default_to("", fallback), do: fallback
  defp default_to(value, _fallback), do: value

  defp to_string_safe(nil), do: nil
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)
end
