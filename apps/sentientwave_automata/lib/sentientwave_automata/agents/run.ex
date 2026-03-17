defmodule SentientwaveAutomata.Agents.Run do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:queued, :running, :succeeded, :failed, :cancelled]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_runs" do
    field :workflow_id, :string
    field :temporal_run_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :queued
    field :error, :map
    field :result, :map
    field :metadata, :map, default: %{}

    belongs_to :agent, SentientwaveAutomata.Agents.AgentProfile
    belongs_to :mention, SentientwaveAutomata.Agents.Mention

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :agent_id,
      :mention_id,
      :workflow_id,
      :temporal_run_id,
      :status,
      :error,
      :result,
      :metadata
    ])
    |> validate_required([:agent_id, :workflow_id, :status])
    |> assoc_constraint(:agent)
    |> assoc_constraint(:mention)
    |> unique_constraint(:workflow_id)
  end
end
