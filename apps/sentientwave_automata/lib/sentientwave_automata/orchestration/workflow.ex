defmodule SentientwaveAutomata.Orchestration.Workflow do
  @moduledoc """
  Domain representation for an orchestrated collaboration run.
  """

  @enforce_keys [:workflow_id, :run_id, :room_id, :objective, :status, :requested_by]
  defstruct [:workflow_id, :run_id, :room_id, :objective, :status, :requested_by, :inserted_at]

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          run_id: String.t(),
          room_id: String.t(),
          objective: String.t(),
          status: atom(),
          requested_by: String.t(),
          inserted_at: DateTime.t()
        }
end
