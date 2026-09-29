defmodule SentientwaveAutomata.OrgChart.TemporalUnavailableError do
  @moduledoc """
  Raised when a mandatory org op cannot be dispatched to its dedicated Temporal
  workflow because the Temporal cluster is unavailable.

  When this is raised the operation was **not** executed inline (no silent data
  mutation), so callers can safely treat it as "not applied — retry once
  Temporal is healthy".
  """

  defexception [:id, :op, :reason]

  @impl true
  def message(%__MODULE__{id: id, reason: reason}) do
    "org op #{inspect(id)} requires a Temporal workflow but Temporal was " <>
      "unavailable (#{inspect(reason)}); no inline fallback was executed"
  end
end
