defmodule SentientwaveAutomata.Agents.Tools.BraveSearch do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  alias SentientwaveAutomata.Agents.Tools.HTTP

  @impl true
  def name, do: "brave_search"

  @impl true
  def description do
    "Search the public web for fresh information and return concise top results with URLs."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Web search query"},
        "count" => %{
          "type" => "integer",
          "description" => "Number of results, 1..10",
          "minimum" => 1,
          "maximum" => 10
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    query = args |> Map.get("query", "") |> to_string() |> String.trim()
    count = args |> Map.get("count", 5) |> normalize_count()
    token = Keyword.get(opts, :api_token, "") |> to_string() |> String.trim()
    base_url = Keyword.get(opts, :base_url, "https://api.search.brave.com")

    cond do
      query == "" ->
        {:error, :missing_query}

      token == "" ->
        {:error, :missing_api_token}

      true ->
        url =
          String.trim_trailing(to_string(base_url), "/") <>
            "/res/v1/web/search?q=#{URI.encode_www_form(query)}&count=#{count}"

        headers = [{"x-subscription-token", token}, {"accept", "application/json"}]

        with {:ok, status, body} <- HTTP.get_json(url, headers),
             true <- status in 200..299 do
          {:ok, format_results(query, body)}
        else
          false -> {:error, :http_error}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp format_results(query, %{"web" => %{"results" => results}}) when is_list(results) do
    items =
      results
      |> Enum.take(5)
      |> Enum.with_index(1)
      |> Enum.map(fn {item, idx} ->
        title = item["title"] || "Untitled"
        url = item["url"] || ""
        desc = item["description"] || ""
        "#{idx}. #{title}\nURL: #{url}\nSummary: #{desc}"
      end)

    %{
      "query" => query,
      "results_count" => length(items),
      "results" => Enum.join(items, "\n\n")
    }
  end

  defp format_results(query, _body) do
    %{
      "query" => query,
      "results_count" => 0,
      "results" => "No web results returned."
    }
  end

  defp normalize_count(value) when is_integer(value), do: min(max(value, 1), 10)

  defp normalize_count(value) do
    case Integer.parse(to_string(value)) do
      {parsed, _} -> normalize_count(parsed)
      :error -> 5
    end
  end
end
