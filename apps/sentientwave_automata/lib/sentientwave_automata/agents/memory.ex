defmodule SentientwaveAutomata.Agents.Memory do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_memories" do
    field :source, :string
    field :content, :string
    field :embedding, {:array, :float}
    field :metadata, :map, default: %{}

    belongs_to :agent, SentientwaveAutomata.Agents.AgentProfile

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:agent_id, :source, :content, :metadata])
    |> validate_required([:agent_id, :content])
    |> put_embedding(attrs)
    |> assoc_constraint(:agent)
  end

  defp put_embedding(changeset, attrs) do
    embedding = Map.get(attrs, :embedding, Map.get(attrs, "embedding"))

    case normalize_embedding(embedding) do
      nil -> add_error(changeset, :embedding, "is required")
      vector -> put_change(changeset, :embedding, vector)
    end
  end

  defp normalize_embedding(nil), do: nil
  defp normalize_embedding(values) when is_list(values), do: Enum.map(values, &to_float/1)
  defp normalize_embedding(_), do: nil

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v / 1.0

  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {parsed, _} -> parsed
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end
