defmodule SentientwaveAutomataWeb.API.OnboardingControllerTest do
  use SentientwaveAutomataWeb.ConnCase

  describe "POST /api/v1/onboarding/validate" do
    test "validates nested provisioning payload", %{conn: conn} do
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
          "visibility" => "private",
          "auto_join" => true
        },
        "invites" => "@alice:acme.org,team@acme.org"
      }

      conn = post(conn, ~p"/api/v1/onboarding/validate", payload)
      body = json_response(conn, 200)

      assert body["data"]["company"]["key"] == "acme"
      assert body["data"]["group"]["key"] == "platform"
      assert body["data"]["invites"] == ["@alice:acme.org", "team@acme.org"]
    end

    test "returns provisioning reason for invalid nested payload", %{conn: conn} do
      payload = %{
        "company" => %{
          "key" => "acme",
          "name" => "Acme Corp",
          "admin_user_id" => "@admin:acme.org"
        },
        "group" => %{"name" => "Platform Team"}
      }

      conn = post(conn, ~p"/api/v1/onboarding/validate", payload)
      body = json_response(conn, 422)

      assert body["errors"]["reason"] == "invalid_group"
    end

    test "returns normalized matrix config", %{conn: conn} do
      payload = %{
        "company_name" => "Acme Corp",
        "group_name" => "Platform Team",
        "homeserver_domain" => "matrix.acme.local",
        "admin_user" => "admin",
        "invitees" => "alice,bob,@carol:matrix.acme.local"
      }

      conn = post(conn, ~p"/api/v1/onboarding/validate", payload)
      body = json_response(conn, 200)

      assert body["data"]["company_name"] == "Acme Corp"
      assert body["data"]["admin_user"] == "@admin:matrix.acme.local"
      assert body["data"]["room_alias"] == "acme-corp-platform-team-automata"
      assert "@alice:matrix.acme.local" in body["data"]["invitees"]
      assert "@carol:matrix.acme.local" in body["data"]["invitees"]
    end

    test "returns validation errors for missing required fields", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/onboarding/validate", %{"company_name" => ""})
      body = json_response(conn, 422)

      assert body["errors"]["group_name"] == "is required"
      assert body["errors"]["homeserver_domain"] == "is required"
      assert body["errors"]["admin_user"] == "is required"
    end
  end
end
