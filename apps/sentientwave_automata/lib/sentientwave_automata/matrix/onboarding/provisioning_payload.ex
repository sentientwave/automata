defmodule SentientwaveAutomata.Matrix.Onboarding.ProvisioningPayload do
  @moduledoc """
  Validates provisioning payloads used by deploy scripts.
  """

  alias SentientwaveAutomata.Matrix.Onboarding.CompanyBootstrapConfig
  alias SentientwaveAutomata.Matrix.Onboarding.GroupBootstrapConfig
  alias SentientwaveAutomata.Matrix.Onboarding.Invites

  @type normalized :: %{
          company: CompanyBootstrapConfig.t(),
          group: GroupBootstrapConfig.t(),
          invites: [String.t()]
        }

  @spec validate(map()) :: {:ok, normalized()} | {:error, atom()}
  def validate(params) when is_map(params) do
    company_params = Map.get(params, "company") || Map.get(params, :company)
    group_params = Map.get(params, "group") || Map.get(params, :group)
    invites_param = Map.get(params, "invites") || Map.get(params, :invites)

    with {:ok, group} <- GroupBootstrapConfig.new(group_params),
         {:ok, company} <- CompanyBootstrapConfig.new(company_params, [group_params]),
         {:ok, invites} <- Invites.parse(invites_param) do
      {:ok, %{company: company, group: group, invites: invites}}
    else
      {:error, :invalid_group} -> {:error, :invalid_group}
      {:error, :invalid_company} -> {:error, :invalid_company}
      {:error, :invalid_invites} -> {:error, :invalid_invites}
      _ -> {:error, :invalid_payload}
    end
  end

  def validate(_), do: {:error, :invalid_payload}
end
