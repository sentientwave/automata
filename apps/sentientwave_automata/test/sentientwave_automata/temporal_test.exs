defmodule SentientwaveAutomata.TemporalTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Temporal

  test "activity_payload stringifies nested keys before adding the step" do
    timestamp = DateTime.from_naive!(~N[2026-03-23 07:22:00], "Etc/UTC")

    payload = %{
      run_id: "run-123",
      attrs: %{
        room_id: "!dm:localhost",
        metadata: %{agent_slug: "automata"},
        tool_calls: [
          %{
            name: "system_directory_admin",
            arguments: %{action: "list_users"},
            issued_at: timestamp
          }
        ]
      }
    }

    assert Temporal.activity_payload("plan_tool_calls", payload) == %{
             "step" => "plan_tool_calls",
             "run_id" => "run-123",
             "attrs" => %{
               "room_id" => "!dm:localhost",
               "metadata" => %{"agent_slug" => "automata"},
               "tool_calls" => [
                 %{
                   "name" => "system_directory_admin",
                   "arguments" => %{"action" => "list_users"},
                   "issued_at" => timestamp
                 }
               ]
             }
           }
  end
end
