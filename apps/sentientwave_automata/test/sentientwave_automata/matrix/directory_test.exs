defmodule SentientwaveAutomata.Matrix.DirectoryTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Matrix.Directory

  test "upserts and lists human, agent, and service users" do
    localpart = "testperson"
    agent = "testagent"
    service = "testservice"

    :ok = Directory.delete_user(localpart)
    :ok = Directory.delete_user(agent)
    :ok = Directory.delete_user(service)

    assert {:ok, person} =
             Directory.upsert_user(%{
               "localpart" => localpart,
               "kind" => "person",
               "display_name" => "Test Person",
               "password" => "person-pass-01",
               "admin" => false
             })

    assert person.localpart == localpart

    assert {:ok, _agent} =
             Directory.upsert_user(%{localpart: agent, kind: :agent, password: "agent-pass-012"})

    assert {:ok, service_user} =
             Directory.upsert_user(%{
               localpart: service,
               kind: :service,
               display_name: "Service Runner",
               password: "service-pass-012"
             })

    users = Directory.list_users()
    assert Enum.any?(users, &(&1.localpart == localpart))
    assert Enum.any?(users, &(&1.localpart == agent))
    assert Enum.any?(users, &(&1.localpart == service))
    assert service_user.kind == :service
    assert Directory.count_users(kind: :service) >= 1
  end

  test "validates short passwords" do
    assert {:error, %{password: _}} =
             Directory.upsert_user(%{
               localpart: "tiny",
               password: "short"
             })
  end
end
