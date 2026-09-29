defmodule SentientwaveAutomata.Adapters.Temporal.RuntimeAdapterTest do
  @moduledoc """
  Regression tests for the real Temporal adapter.

  The key guard here: `TemporalSdk.start_workflow` must be called with
  `opentelemetry: false`. The SDK 0.2.x line defaults that option to `true` in
  production builds and injects a traceparent into the workflow start header.
  With only `opentelemetry_api` present (no OpenTelemetry SDK installed), the
  no-op tracer returns a non-recording span and the SDK's own
  `true = otel_span:add_events/2` crashes the workflow task executor at init
  with `{:badmatch, false}` — every workflow task, every workflow, on every
  deploy (observed 2026-08-30 on temporal_sdk 0.2.20).
  """
  use SentientwaveAutomata.DataCase, async: false

  # Swaps the loaded `TemporalSdk` module for a capture mock (and back) using
  # BEAM-level code swapping; Elixir 1.19 exposes no public put_override API.
  defp with_temporal_sdk_mock(fun) do
    Code.ensure_loaded(TemporalSdk)
    {_mod, original_beam, original_file} = :code.get_object_code(TemporalSdk)
    :code.purge(TemporalSdk)

    [{_mock_mod, _mock_beam}] =
      Code.compile_quoted(
        quote do
          defmodule TemporalSdk do
            def start_workflow(_cluster, _queue, _module, opts) do
              Process.put(:captured_temporal_opts, opts)

              {:ok,
               %{
                 workflow_execution: %{
                   workflow_id: Keyword.get(opts, :workflow_id, "wf-captured"),
                   run_id: "run-captured"
                 }
               }}
            end

            def signal_workflow(_cluster, _execution, _signal, _opts \\ []), do: {:ok, %{}}
            def get_workflow_state(_cluster, _execution, _opts \\ []), do: {:ok, %{}}
          end
        end,
        "test_temporal_sdk_mock"
      )

    try do
      fun.()
    after
      :code.purge(TemporalSdk)
      :code.load_binary(TemporalSdk, original_file, original_beam)
    end
  end

  describe "TemporalSdk.start_workflow options" do
    test "adapter disables SDK opentelemetry header injection" do
      with_temporal_sdk_mock(fn ->
        result =
          SentientwaveAutomata.Adapters.Temporal.Runtime.start_workflow(
            "scheduled_task_workflow",
            %{"workflow_id" => "scheduled_task_test-1"},
            workflow_id: "scheduled_task_test-1"
          )

        assert {:ok, %{workflow_id: "scheduled_task_test-1", status: :running}} = result
        opts = Process.get(:captured_temporal_opts)
        assert opts != nil
        assert Keyword.get(opts, :opentelemetry) == false
      end)
    end

    test "start_agent_run disables SDK opentelemetry header injection" do
      with_temporal_sdk_mock(fn ->
        result =
          SentientwaveAutomata.Adapters.Temporal.Runtime.start_agent_run(%{"agent_id" => "a1"})

        assert {:ok, %{status: :running}} = result
        opts = Process.get(:captured_temporal_opts)
        assert opts != nil
        assert Keyword.get(opts, :opentelemetry) == false
      end)
    end
  end
end
