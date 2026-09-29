defmodule SentientwaveAutomata.OrgChart.OrgUnit do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "org_units" do
    field :name, :string
    field :kind, :string, default: "team"
    field :department, :string
    field :mission, :string
    field :head, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(unit, attrs) do
    unit
    |> cast(attrs, [:name, :kind, :department, :mission, :head])
    |> validate_required([:name, :kind])
    |> unique_constraint([:name, :kind])
  end
end
