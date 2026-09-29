defmodule SentientwaveAutomata.Agents.Tools.BraveSearch do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  alias SentientwaveAutomata.Agents.Tools.HTTP

  @default_result_limit 5
  @default_query_limit 4

  @impl true
  def name, do: "brave_search"

  @impl true
  def description do
    "Search the public web with one or more related queries and return merged evidence with URLs."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Web search query"},
        "queries" => %{
          "type" => "array",
          "description" => "Optional related queries to run alongside the primary query",
          "items" => %{"type" => "string"},
          "minItems" => 1,
          "maxItems" => @default_query_limit
        },
        "count" => %{
          "type" => "integer",
          "description" => "Number of results per query, 1..10",
          "minimum" => 1,
          "maximum" => 10
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    # The durable activity cannot see this process' opts, so the configured
    # credentials travel inside the job args.
    args =
      args
      |> Map.put_new("api_token", Keyword.get(opts, :api_token, "") |> to_string())
      |> Map.put_new("base_url", Keyword.get(opts, :base_url, "") |> to_string())
      |> Map.put_new("wait", true)

    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch("brave_search", args, opts, :search_failed)
  end

  @doc "Direct (non-Temporal) execution used by org-ops activities and tests."
  def execute_direct(args, opts \\ []) when is_map(args) do
    query = args |> Map.get("query", "") |> to_string() |> String.trim()
    queries = normalize_queries(query, Map.get(args, "queries", []))
    count = args |> Map.get("count", 5) |> normalize_count()

    token =
      (Keyword.get(opts, :api_token) || Map.get(args, "api_token", ""))
      |> to_string()
      |> String.trim()

    base_url =
      [Keyword.get(opts, :base_url), Map.get(args, "base_url", "")]
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.at(0, "https://api.search.brave.com")

    http_client = Keyword.get(opts, :http_client, HTTP)
    http_opts = Keyword.get(opts, :http_opts, [])

    cond do
      query == "" ->
        {:error, :missing_query}

      token == "" ->
        {:error, :missing_api_token}

      true ->
        headers = [{"x-subscription-token", token}, {"accept", "application/json"}]

        searches =
          Enum.map(queries, fn search_query ->
            perform_search(http_client, http_opts, base_url, headers, search_query, count)
          end)

        merged_evidence = merge_evidence(searches)
        result = format_results(query, queries, count, searches, merged_evidence)

        if Enum.all?(searches, &(&1["status"] == "error")) do
          {:error, {:search_failed, Enum.map(searches, &Map.take(&1, ["query", "error"]))}}
        else
          {:ok, result}
        end
    end
  end

  defp perform_search(http_client, http_opts, base_url, headers, query, count) do
    url = search_url(base_url, query, count)

    case http_client.get_json(url, headers, http_opts) do
      {:ok, status, body} when status in 200..299 ->
        evidence = extract_evidence(body, query, count)

        %{
          "query" => query,
          "status" => "ok",
          "results_count" => length(evidence),
          "results" => summarize_evidence(evidence),
          "evidence" => evidence
        }

      {:ok, status, body} ->
        %{
          "query" => query,
          "status" => "error",
          "error" => %{"type" => "http_error", "status" => status, "body" => body},
          "results_count" => 0,
          "results" => "",
          "evidence" => []
        }

      {:error, reason} ->
        %{
          "query" => query,
          "status" => "error",
          "error" => normalize_error(reason),
          "results_count" => 0,
          "results" => "",
          "evidence" => []
        }
    end
  end

  defp format_results(query, queries, count, searches, merged_evidence) do
    %{
      "query" => query,
      "queries" => queries,
      "count" => count,
      "search_count" => length(searches),
      "raw_results_count" =>
        Enum.reduce(searches, 0, fn search, acc -> acc + search["results_count"] end),
      "results_count" => length(merged_evidence),
      "searches" => searches,
      "evidence" => merged_evidence,
      "results" => summarize_evidence(merged_evidence)
    }
  end

  defp extract_evidence(%{"web" => %{"results" => results}}, query, count)
       when is_list(results) do
    results
    |> Enum.take(count)
    |> Enum.map(&normalize_result(&1, query))
  end

  defp extract_evidence(_body, _query, _count), do: []

  defp normalize_result(item, source_query) when is_map(item) do
    %{
      "title" => Map.get(item, "title", "Untitled") |> to_string(),
      "url" => Map.get(item, "url", "") |> to_string(),
      "description" => Map.get(item, "description", "") |> to_string(),
      "source_query" => source_query
    }
  end

  defp normalize_result(item, source_query) do
    %{
      "title" => to_string(item),
      "url" => "",
      "description" => "",
      "source_query" => source_query
    }
  end

  defp merge_evidence(searches) do
    {evidence, _seen} =
      searches
      |> Enum.filter(&(&1["status"] == "ok"))
      |> Enum.flat_map(&Map.get(&1, "evidence", []))
      |> Enum.reduce({[], %{}}, fn item, {acc, seen} ->
        key = evidence_key(item)

        case Map.fetch(seen, key) do
          {:ok, index} ->
            updated = merge_evidence_item(Enum.at(acc, index), item)
            {List.replace_at(acc, index, updated), seen}

          :error ->
            index = length(acc)
            {acc ++ [put_source_queries(item)], Map.put(seen, key, index)}
        end
      end)

    evidence
  end

  defp put_source_queries(item) do
    item
    |> Map.put_new("source_queries", [Map.get(item, "source_query", "")])
    |> Map.delete("source_query")
  end

  defp merge_evidence_item(existing, incoming) do
    existing_sources = Map.get(existing, "source_queries", [])
    incoming_sources = [Map.get(incoming, "source_query", "")]

    existing
    |> Map.put("source_queries", Enum.uniq(existing_sources ++ incoming_sources))
  end

  defp evidence_key(item) do
    case Map.get(item, "url", "") |> to_string() |> String.trim() do
      "" ->
        item |> Map.get("title", "") |> to_string() |> String.trim()

      url ->
        canonicalize_url(url)
    end
  end

  defp canonicalize_url(url) do
    case URI.parse(url) do
      %URI{} = uri ->
        uri
        |> Map.put(:fragment, nil)
        |> URI.to_string()
        |> String.trim_trailing("/")

      _ ->
        String.trim_trailing(url, "/")
    end
  end

  defp summarize_evidence(items) do
    items
    |> Enum.take(@default_result_limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {item, idx} ->
      title = Map.get(item, "title", "Untitled")
      url = Map.get(item, "url", "")
      desc = Map.get(item, "description", "")

      sources =
        Map.get(item, "source_queries", []) |> Enum.reject(&(&1 == "")) |> Enum.join(" | ")

      [
        "#{idx}. #{title}",
        "URL: #{url}",
        "Summary: #{desc}",
        if(sources == "", do: nil, else: "Source queries: #{sources}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end)
    |> case do
      [] -> "No web results returned."
      items -> Enum.join(items, "\n\n")
    end
  end

  defp normalize_queries(query, queries) do
    [query | List.wrap(queries)]
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@default_query_limit)
  end

  defp search_url(base_url, query, count) do
    String.trim_trailing(to_string(base_url), "/") <>
      "/res/v1/web/search?q=#{URI.encode_www_form(query)}&count=#{count}"
  end

  defp normalize_error(reason) when is_binary(reason),
    do: %{"type" => "error", "reason" => reason}

  defp normalize_error(reason), do: %{"type" => "error", "reason" => inspect(reason)}

  defp normalize_count(value) when is_integer(value), do: min(max(value, 1), 10)

  defp normalize_count(value) do
    case Integer.parse(to_string(value)) do
      {parsed, _} -> normalize_count(parsed)
      :error -> 5
    end
  end
end
