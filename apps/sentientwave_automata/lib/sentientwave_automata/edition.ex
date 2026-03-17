defmodule SentientwaveAutomata.Edition do
  @moduledoc """
  Edition-level feature gates for open-core packaging.
  """

  @type t :: :community | :enterprise

  @default_features %{
    community:
      MapSet.new([
        :matrix_rooms,
        :basic_orchestration,
        :local_tooling,
        :basic_audit
      ]),
    enterprise:
      MapSet.new([
        :matrix_rooms,
        :basic_orchestration,
        :local_tooling,
        :basic_audit,
        :sso,
        :advanced_policy,
        :seat_management,
        :compliance_export,
        :dedicated_isolation
      ])
  }

  @spec current() :: t()
  def current do
    Application.get_env(:sentientwave_automata, :edition, :community)
  end

  @spec has_feature?(atom(), t()) :: boolean()
  def has_feature?(feature, edition \\ current()) do
    @default_features
    |> Map.fetch!(edition)
    |> MapSet.member?(feature)
  end

  @spec feature_matrix() :: map()
  def feature_matrix, do: @default_features
end
