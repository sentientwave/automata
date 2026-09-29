defmodule SentientwaveAutomata.OrgChartJobsTest do
  @moduledoc """
  Security regression tests for persisted org-operation job records: tools
  like brave_search carry their configured API token inside the job args (the
  durable activity cannot read process opts), so the stored row must not leak
  the raw token through the org-jobs API.
  """
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.OrgChart.Jobs

  test "create_or_get masks api_token in the persisted args" do
    workflow_id = "org_ops_mask_test_#{System.unique_integer([:positive])}"

    {:ok, job} =
      Jobs.create_or_get(%{
        workflow_id: workflow_id,
        op: "brave_search",
        args: %{
          "query" => "elixir security",
          "api_token" => "sekrit-token-value",
          "base_url" => "https://api.search.brave.com"
        },
        requested_by: "alice"
      })

    assert job.args["api_token"] == "***"
    assert job.args["query"] == "elixir security"
    assert job.args["base_url"] == "https://api.search.brave.com"
  end

  test "args without a token are stored unchanged" do
    workflow_id = "org_ops_no_mask_test_#{System.unique_integer([:positive])}"

    {:ok, job} =
      Jobs.create_or_get(%{
        workflow_id: workflow_id,
        op: "create_department",
        args: %{"name" => "Ops"},
        requested_by: "bob"
      })

    assert job.args == %{"name" => "Ops"}
  end
end
