defmodule SentientwaveAutomata.Matrix.ReconciliationWorker do
  @moduledoc """
  Periodically reconciles internal Automata directory users into Matrix.
  """

  use GenServer
  require Logger

  alias SentientwaveAutomata.Matrix.Reconciler

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_reconcile(1_500)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    result = Reconciler.reconcile()

    Logger.info(
      "matrix_reconcile ok=#{length(result.ok)} failed=#{length(result.failed)} failed_items=#{inspect(result.failed)}"
    )

    schedule_reconcile(interval_ms())
    {:noreply, state}
  end

  defp schedule_reconcile(ms), do: Process.send_after(self(), :reconcile, ms)

  defp interval_ms,
    do: System.get_env("MATRIX_RECONCILE_INTERVAL_MS", "60000") |> String.to_integer()
end
