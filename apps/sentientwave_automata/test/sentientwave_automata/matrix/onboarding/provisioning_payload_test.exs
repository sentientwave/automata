defmodule SentientwaveAutomata.Matrix.Onboarding.ProvisioningPayloadTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Matrix.Onboarding.CompanyBootstrapConfig
  alias SentientwaveAutomata.Matrix.Onboarding.Invites
  alias SentientwaveAutomata.Matrix.Onboarding.ProvisioningPayload

  describe "CompanyBootstrapConfig.new/2" do
    test "builds company config with group defaults" do
      company = %{"key" => "acme", "name" => "Acme Corp", "admin_user_id" => "@admin:acme.org"}
      group = %{"key" => "platform", "name" => "Platform Team"}

      assert {:ok, config} = CompanyBootstrapConfig.new(company, group)
      assert config.company_key == "acme"
      assert config.default_group_key == "platform"
      assert length(config.groups) == 1
    end
  end

  describe "Invites.parse/1" do
    test "parses matrix ids and email invites" do
      raw = "@alice:acme.org,ops@acme.org\n@bob:acme.org"

      assert {:ok, invites} = Invites.parse(raw)
      assert invites == ["@alice:acme.org", "ops@acme.org", "@bob:acme.org"]
    end

    test "returns error for invalid entries" do
      assert {:error, :invalid_invites} = Invites.parse(["not valid"])
    end
  end

  describe "ProvisioningPayload.validate/1" do
    test "normalizes valid nested provisioning payload" do
      payload = %{
        "company" => %{
          "key" => "acme",
          "name" => "Acme Corp",
          "admin_user_id" => "@admin:acme.org",
          "homeserver" => "acme.org"
        },
        "group" => %{
          "key" => "platform",
          "name" => "Platform Team",
          "visibility" => "private"
        },
        "invites" => "@alice:acme.org,team@acme.org"
      }

      assert {:ok, normalized} = ProvisioningPayload.validate(payload)
      assert normalized.company.company_key == "acme"
      assert normalized.group.key == "platform"
      assert normalized.invites == ["@alice:acme.org", "team@acme.org"]
    end

    test "returns invalid_group when group payload is missing required key" do
      payload = %{
        "company" => %{
          "key" => "acme",
          "name" => "Acme Corp",
          "admin_user_id" => "@admin:acme.org"
        },
        "group" => %{"name" => "Platform Team"}
      }

      assert {:error, :invalid_group} = ProvisioningPayload.validate(payload)
    end
  end
end
