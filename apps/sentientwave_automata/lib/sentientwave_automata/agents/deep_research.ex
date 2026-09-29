defmodule SentientwaveAutomata.Agents.DeepResearch do
  @moduledoc """
  Shared heuristics and normalization for deep research execution.
  """

  @explicit_phrases [
    "deep research",
    "research this deeply",
    "research thoroughly",
    "thoroughly research",
    "in-depth research",
    "comprehensive research",
    "investigate deeply",
    "do thorough research"
  ]

  @complexity_phrases [
    "latest",
    "recent",
    "current",
    "compare",
    "comparison",
    "analyze",
    "analysis",
    "evaluate",
    "investigate",
    "report",
    "brief",
    "sources",
    "citations",
    "evidence",
    "market",
    "landscape",
    "competitive",
    "trend"
  ]

  @default_max_rounds 2
  @default_max_queries_per_round 3
  @default_results_per_query 5

  @spec config() :: map()
  def config do
    %{
      "max_rounds" => bounded_env_int(:deep_research_max_rounds, @default_max_rounds, 1, 4),
      "max_queries_per_round" =>
        bounded_env_int(
          :deep_research_max_queries_per_round,
          @default_max_queries_per_round,
          1,
          5
        ),
      "results_per_query" =>
        bounded_env_int(:deep_research_results_per_query, @default_results_per_query, 1, 10)
    }
  end

  @coordination_phrases [
    "send_matrix_message",
    "direct-message",
    "direct message",
    "dm a colleague",
    "dm them",
    "message them"
  ]

  @spec should_consider?(String.t(), [map()]) :: boolean()
  def should_consider?(user_input, available_tools)
      when is_binary(user_input) and is_list(available_tools) do
    brave_search_available?(available_tools) and
      (explicit_request?(user_input) or complexity_candidate?(user_input)) and
      not coordination_request?(user_input)
  end

  @doc """
  True when the request is about messaging/coordinating with colleagues via
  the send_matrix_message tool rather than researching the web.
  """
  @spec coordination_request?(String.t()) :: boolean()
  def coordination_request?(user_input) when is_binary(user_input) do
    normalized = normalize_input(user_input)
    Enum.any?(@coordination_phrases, &String.contains?(normalized, &1))
  end

  @spec explicit_request?(String.t()) :: boolean()
  def explicit_request?(user_input) when is_binary(user_input) do
    normalized = normalize_input(user_input)
    Enum.any?(@explicit_phrases, &String.contains?(normalized, &1))
  end

  @spec complexity_candidate?(String.t()) :: boolean()
  def complexity_candidate?(user_input) when is_binary(user_input) do
    normalized = normalize_input(user_input)
    word_count = normalized |> String.split(~r/\s+/, trim: true) |> length()

    phrase_match? = Enum.any?(@complexity_phrases, &String.contains?(normalized, &1))
    long_prompt? = word_count >= 18 or String.length(normalized) >= 140
    multi_part? = Regex.match?(~r/\b(and|versus|vs\.?|pros and cons|tradeoffs?)\b/u, normalized)
    multi_question? = String.contains?(normalized, "?") and String.length(normalized) >= 80

    phrase_match? and (long_prompt? or multi_part? or multi_question?)
  end

  @spec fallback_decision(String.t(), [map()]) :: map()
  def fallback_decision(user_input, available_tools)
      when is_binary(user_input) and is_list(available_tools) do
    limits = config()
    enabled = should_consider?(user_input, available_tools)
    explicit = explicit_request?(user_input)

    %{
      "mode" => if(enabled, do: "deep_research", else: "standard"),
      "enabled" => enabled,
      "requested_by_user" => explicit,
      "reason" =>
        cond do
          not brave_search_available?(available_tools) -> "brave_search_unavailable"
          explicit -> "explicit_user_request"
          complexity_candidate?(user_input) -> "complexity_heuristic"
          true -> "standard_response"
        end,
      "max_rounds" => if(enabled, do: limits["max_rounds"], else: 0),
      "queries" =>
        if(enabled, do: fallback_queries(user_input, limits["max_queries_per_round"]), else: []),
      "focus_areas" => []
    }
  end

  @spec normalize_decision(map(), String.t(), [map()]) :: map()
  def normalize_decision(payload, user_input, available_tools)
      when is_map(payload) and is_binary(user_input) and is_list(available_tools) do
    fallback = fallback_decision(user_input, available_tools)
    limits = config()
    enabled = normalize_bool(fetch_value(payload, "enabled"), fallback["enabled"])

    explicit =
      normalize_bool(fetch_value(payload, "requested_by_user"), fallback["requested_by_user"])

    queries =
      normalize_queries(
        fetch_value(payload, "queries"),
        fallback["queries"],
        limits["max_queries_per_round"]
      )

    %{
      "mode" => if(enabled, do: "deep_research", else: "standard"),
      "enabled" => enabled,
      "requested_by_user" => explicit,
      "reason" => normalize_reason(fetch_value(payload, "reason"), fallback["reason"]),
      "max_rounds" =>
        if(enabled,
          do:
            normalize_int(
              fetch_value(payload, "max_rounds"),
              fallback["max_rounds"],
              1,
              limits["max_rounds"]
            ),
          else: 0
        ),
      "queries" => if(enabled, do: queries, else: []),
      "focus_areas" => normalize_strings(fetch_value(payload, "focus_areas"), 5)
    }
  end

  @spec normalize_round_review(map(), [map()], non_neg_integer(), pos_integer()) :: map()
  def normalize_round_review(payload, evidence, round_index, max_rounds)
      when is_map(payload) and is_list(evidence) do
    limits = config()

    follow_up_queries =
      normalize_queries(
        fetch_value(payload, "follow_up_queries"),
        [],
        limits["max_queries_per_round"]
      )

    continue? =
      round_index < max_rounds and
        normalize_bool(fetch_value(payload, "continue_research"), follow_up_queries != [])

    %{
      "round_summary" => normalize_summary(fetch_value(payload, "round_summary"), evidence),
      "continue_research" => continue?,
      "follow_up_queries" => if(continue?, do: follow_up_queries, else: []),
      "key_findings" => normalize_strings(fetch_value(payload, "key_findings"), 6),
      "top_sources" => normalize_sources(fetch_value(payload, "top_sources"), evidence)
    }
  end

  @spec render_evidence_for_prompt([map()]) :: String.t()
  def render_evidence_for_prompt(evidence) when is_list(evidence) do
    evidence
    |> Enum.map(fn entry ->
      query = fetch_value(entry, "query") || "unknown query"
      findings = normalize_strings(fetch_value(entry, "findings"), 5)
      sources = normalize_sources(fetch_value(entry, "sources"), [])

      [
        "Query: #{query}",
        if(findings == [], do: nil, else: "Findings:\n- " <> Enum.join(findings, "\n- ")),
        if(
          sources == [],
          do: nil,
          else:
            "Sources:\n- " <>
              Enum.map_join(sources, "\n- ", fn source ->
                title = Map.get(source, "title", "Untitled")
                url = Map.get(source, "url", "")
                summary = Map.get(source, "summary", "")
                "#{title} (#{url})#{if(summary == "", do: "", else: ": #{summary}")}"
              end)
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp fallback_queries(user_input, limit) do
    cleaned =
      user_input
      |> String.replace(~r/\b(deep|thorough|comprehensive|in-depth)\s+research\b/iu, "")
      |> String.replace(~r/\bresearch\b/iu, "")
      |> String.trim()

    base_query =
      case cleaned do
        "" -> "current overview"
        value -> value
      end

    variants =
      [
        base_query,
        base_query <> " latest developments",
        base_query <> " analysis"
      ]

    normalize_queries(variants, [base_query], limit)
  end

  @spec brave_search_available?([map()]) :: boolean()
  def brave_search_available?(available_tools) when is_list(available_tools) do
    Enum.any?(
      available_tools,
      &(Map.get(&1, :name) == "brave_search" or Map.get(&1, "name") == "brave_search")
    )
  end

  def brave_search_available?(_available_tools), do: false

  defp normalize_input(user_input) do
    user_input
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp normalize_summary(value, evidence) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback_summary(evidence)
      trimmed -> trimmed
    end
  end

  defp normalize_summary(_value, evidence), do: fallback_summary(evidence)

  defp fallback_summary(evidence) do
    if evidence == [] do
      "No research evidence was gathered in this round."
    else
      "Collected #{length(evidence)} research evidence set(s) for review."
    end
  end

  defp normalize_sources(value, evidence) when is_list(value) do
    value
    |> Enum.map(&normalize_source/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(6)
    |> case do
      [] -> fallback_sources(evidence)
      sources -> sources
    end
  end

  defp normalize_sources(_value, evidence), do: fallback_sources(evidence)

  defp fallback_sources(evidence) do
    evidence
    |> Enum.flat_map(fn entry ->
      normalize_sources(fetch_value(entry, "sources"), [])
    end)
    |> Enum.uniq_by(&Map.get(&1, "url"))
    |> Enum.take(6)
  end

  defp normalize_source(%{} = source) do
    title = fetch_value(source, "title") |> to_string_safe() |> String.trim()
    url = fetch_value(source, "url") |> to_string_safe() |> String.trim()
    summary = fetch_value(source, "summary") |> to_string_safe() |> String.trim()

    cond do
      url == "" -> nil
      true -> %{"title" => default_string(title, "Untitled"), "url" => url, "summary" => summary}
    end
  end

  defp normalize_source(_), do: nil

  defp normalize_queries(value, fallback, limit) do
    value
    |> normalize_strings(limit)
    |> case do
      [] -> normalize_strings(fallback, limit)
      queries -> queries
    end
    |> Enum.uniq()
    |> Enum.take(limit)
  end

  defp normalize_strings(value, limit) when is_list(value) do
    value
    |> Enum.map(&to_string_safe/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(limit)
  end

  defp normalize_strings(value, limit) when is_binary(value) do
    value
    |> String.split(~r/[\n,;]/u, trim: true)
    |> normalize_strings(limit)
  end

  defp normalize_strings(_value, _limit), do: []

  defp normalize_reason(value, fallback) do
    value
    |> to_string_safe()
    |> String.trim()
    |> default_string(fallback)
  end

  defp normalize_bool(value, _default) when is_boolean(value), do: value
  defp normalize_bool(value, _default) when value in ["true", "yes", "1"], do: true
  defp normalize_bool(value, _default) when value in ["false", "no", "0"], do: false
  defp normalize_bool(_value, default), do: default

  defp normalize_int(value, _default, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp normalize_int(value, default, min_value, max_value) do
    case Integer.parse(to_string_safe(value)) do
      {parsed, _} -> normalize_int(parsed, default, min_value, max_value)
      :error -> default
    end
  end

  defp bounded_env_int(key, default, min_value, max_value) do
    :sentientwave_automata
    |> Application.get_env(key, default)
    |> normalize_int(default, min_value, max_value)
  end

  defp fetch_value(map, key) when is_map(map) do
    atom_key =
      case key do
        "enabled" -> :enabled
        "requested_by_user" -> :requested_by_user
        "reason" -> :reason
        "max_rounds" -> :max_rounds
        "queries" -> :queries
        "focus_areas" -> :focus_areas
        "continue_research" -> :continue_research
        "follow_up_queries" -> :follow_up_queries
        "round_summary" -> :round_summary
        "key_findings" -> :key_findings
        "top_sources" -> :top_sources
        "title" -> :title
        "url" -> :url
        "summary" -> :summary
        "query" -> :query
        "findings" -> :findings
        "sources" -> :sources
        _ -> nil
      end

    Map.get(map, key) || (atom_key && Map.get(map, atom_key))
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)

  defp default_string("", fallback), do: fallback
  defp default_string(nil, fallback), do: fallback
  defp default_string(value, _fallback), do: value
end
