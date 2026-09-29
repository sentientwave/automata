defmodule SentientwaveAutomata.Agents.Tools.BraveSearchTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Agents.Tools.BraveSearch

  @base_url "https://api.search.brave.com"
  @token "test-token"

  test "runs multiple related searches and merges deduped evidence" do
    put_responses(%{
      "primary query" => {:ok, 200, brave_body(primary_results())},
      "related query" => {:ok, 200, brave_body(related_results())},
      "source query" => {:ok, 200, brave_body(source_results())}
    })

    assert {:ok, result} =
             BraveSearch.execute_direct(
               %{
                 "query" => "primary query",
                 "queries" => ["related query", "source query"],
                 "count" => 2
               },
               api_token: @token,
               base_url: @base_url,
               http_client: SentientwaveAutomata.TestSupport.BraveHTTPStub
             )

    assert result["query"] == "primary query"
    assert result["queries"] == ["primary query", "related query", "source query"]
    assert result["count"] == 2
    assert result["search_count"] == 3
    assert result["raw_results_count"] == 5
    assert result["results_count"] == 4
    assert length(result["searches"]) == 3
    assert length(result["evidence"]) == 4

    assert Enum.map(result["evidence"], & &1["title"]) == [
             "Primary evidence",
             "Shared evidence",
             "Related evidence",
             "Source evidence"
           ]

    assert String.contains?(result["results"], "Primary evidence")
    assert String.contains?(result["results"], "Shared evidence")
    assert String.contains?(result["results"], "Source queries:")

    assert_requests([
      {"primary query", 2},
      {"related query", 2},
      {"source query", 2}
    ])
  end

  test "keeps successful evidence when one search fails" do
    put_responses(%{
      "primary query" => {:ok, 200, brave_body(primary_results())},
      "related query" => {:error, {:timeout, 1000}}
    })

    assert {:ok, result} =
             BraveSearch.execute_direct(
               %{
                 "query" => "primary query",
                 "queries" => ["related query"],
                 "count" => 1
               },
               api_token: @token,
               base_url: @base_url,
               http_client: SentientwaveAutomata.TestSupport.BraveHTTPStub
             )

    assert result["search_count"] == 2
    assert result["results_count"] == 1
    assert length(result["searches"]) == 2
    assert Enum.any?(result["searches"], &(&1["status"] == "error"))
    assert Enum.any?(result["searches"], &(&1["status"] == "ok"))

    assert match?(
             %{"type" => "error", "reason" => _},
             Enum.find_value(result["searches"], & &1["error"])
           )
  end

  test "returns an error when every search fails" do
    put_responses(%{
      "primary query" => {:error, :timeout},
      "related query" => {:error, :timeout}
    })

    assert {:error, {:search_failed, failures}} =
             BraveSearch.execute_direct(
               %{
                 "query" => "primary query",
                 "queries" => ["related query"],
                 "count" => 1
               },
               api_token: @token,
               base_url: @base_url,
               http_client: SentientwaveAutomata.TestSupport.BraveHTTPStub
             )

    assert length(failures) == 2
  end

  defp put_responses(responses) do
    Process.put(:brave_http_test_pid, self())
    Process.put(:brave_http_responses, responses)
  end

  defp brave_body(results) do
    %{"web" => %{"results" => results}}
  end

  defp primary_results do
    [
      %{
        "title" => "Primary evidence",
        "url" => "https://example.com/a",
        "description" => "Primary source summary"
      },
      %{
        "title" => "Shared evidence",
        "url" => "https://example.com/shared",
        "description" => "Shared source summary"
      }
    ]
  end

  defp related_results do
    [
      %{
        "title" => "Shared evidence",
        "url" => "https://example.com/shared",
        "description" => "Shared source summary"
      },
      %{
        "title" => "Related evidence",
        "url" => "https://example.com/b",
        "description" => "Related source summary"
      }
    ]
  end

  defp source_results do
    [
      %{
        "title" => "Source evidence",
        "url" => "https://example.com/c",
        "description" => "Source summary"
      }
    ]
  end

  defp assert_requests(expected) do
    requests =
      for _ <- expected do
        assert_receive {:brave_http_request, request}
        request
      end

    Enum.zip(requests, expected)
    |> Enum.each(fn {request, {query, count}} ->
      assert {"x-subscription-token", @token} in request.headers
      assert {"accept", "application/json"} in request.headers

      parsed = URI.parse(request.url)
      params = URI.decode_query(parsed.query || "")

      assert params["q"] == query
      assert params["count"] == Integer.to_string(count)
    end)
  end
end
