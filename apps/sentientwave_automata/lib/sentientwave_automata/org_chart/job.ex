defmodule SentientwaveAutomata.OrgChart.Job do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "org_operation_jobs" do
    field :workflow_id, :string
    field :op, :string
    field :args, :map, default: %{}
    field :requested_by, :string
    field :status, :string, default: "queued"
    field :result, :map
    field :error, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(job, attrs) do
    import Ecto.Changeset

    job
    |> cast(attrs, [:workflow_id, :op, :args, :requested_by, :status, :result, :error])
    |> validate_required([:workflow_id, :op])
    |> unique_constraint(:workflow_id)
  end
end
