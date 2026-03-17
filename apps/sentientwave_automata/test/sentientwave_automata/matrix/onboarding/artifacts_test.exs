defmodule SentientwaveAutomata.Matrix.Onboarding.ArtifactsTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Matrix.Onboarding.Artifacts

  @status %{
    matrix_admin_user: "@admin:localhost",
    matrix_admin_password: "admin-secret",
    invite_password: "invite-secret",
    matrix_url: "http://localhost:8008",
    room_alias: "#acme-core-automata:localhost",
    automata_url: "http://localhost:4000"
  }

  test "keeps passwords hidden unless explicitly enabled" do
    artifacts = Artifacts.build(@status, users_input: "alice,@admin:localhost")

    assert artifacts.include_passwords == false
    assert Enum.all?(artifacts.users, &(&1.password == ""))
    assert Enum.all?(artifacts.users, &String.contains?(&1.password_display, "hidden"))
  end

  test "includes onboarding links and passwords when explicitly enabled" do
    artifacts =
      Artifacts.build(@status, users_input: "alice,@admin:localhost", include_passwords: true)

    [first | _] = artifacts.users
    assert String.starts_with?(first.onboarding_url, "http://localhost:4000/onboarding/user?")
    assert first.password_display != "(hidden until explicitly enabled)"
  end
end
