defmodule SentientwaveAutomata.Agents.AgentWallet do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_wallets" do
    field :wallet_ref, :string
    field :kind, :string, default: "personal"
    field :status, :string, default: "active"
    field :balance, :integer, default: 0
    field :matrix_credentials, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :agent, SentientwaveAutomata.Agents.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(wallet, attrs) do
    wallet
    |> cast(attrs, [
      :agent_id,
      :wallet_ref,
      :kind,
      :status,
      :balance,
      :matrix_credentials,
      :metadata
    ])
    |> ensure_wallet_ref()
    |> validate_required([:agent_id, :wallet_ref, :kind, :status])
    |> validate_length(:wallet_ref, min: 6, max: 128)
    |> validate_number(:balance, greater_than_or_equal_to: 0)
    |> assoc_constraint(:agent)
    |> unique_constraint(:agent_id)
    |> unique_constraint(:wallet_ref)
  end

  defp ensure_wallet_ref(changeset) do
    case get_field(changeset, :wallet_ref) do
      value when is_binary(value) and value != "" ->
        changeset

      _ ->
        put_change(changeset, :wallet_ref, "wlt_" <> Ecto.UUID.generate())
    end
  end
end
