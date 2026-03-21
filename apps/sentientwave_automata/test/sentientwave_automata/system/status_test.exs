defmodule SentientwaveAutomata.System.StatusTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.System.Status

  test "reads connection info from file when available" do
    path =
      Path.join(System.tmp_dir!(), "sw-connection-info-#{System.unique_integer([:positive])}.txt")

    File.write!(path, """
    Company: ACME Inc
    Group: Platform
    Matrix URL: http://localhost:8008
    Matrix Admin User: @admin:localhost
    Matrix Admin Password: secret
    Room Alias: #acme-platform-automata:localhost
    Governance Room Alias: #acme-governance:localhost
    Invite Password: invite-secret
    Automata URL: http://localhost:4000
    """)

    summary = Status.summary(connection_info_path: path)

    assert summary.company_name == "ACME Inc"
    assert summary.group_name == "Platform"
    assert summary.matrix_admin_user == "@admin:localhost"
    assert summary.room_alias == "#acme-platform-automata:localhost"
    assert summary.governance_room_alias == "#acme-governance:localhost"
    assert summary.source == "connection-info"

    File.rm(path)
  end

  test "falls back to defaults when connection info file is missing" do
    summary =
      Status.summary(
        connection_info_path: "/tmp/does-not-exist-#{System.unique_integer([:positive])}.txt"
      )

    assert summary.company_name == "SentientWave"
    assert summary.group_name == "Core Team"
    assert summary.source == "env"
    assert summary.matrix_url == "http://localhost:8008"
    assert summary.governance_room_alias == "governance"
  end
end
