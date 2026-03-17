defmodule SentientwaveAutomata.Matrix.DirectoryTest do
  use ExUnit.Case, async: false

  alias SentientwaveAutomata.Matrix.Directory

  test "upserts and lists people/agent users" do
    localpart = "testperson"
    agent = "testagent"

    :ok = Directory.delete_user(localpart)
    :ok = Directory.delete_user(agent)

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
             Directory.upsert_user(%{localpart: agent, kind: :agent, password: "agent-pass-01"})

    users = Directory.list_users()
    assert Enum.any?(users, &(&1.localpart == localpart))
    assert Enum.any?(users, &(&1.localpart == agent))
  end

  test "validates short passwords" do
    assert {:error, %{password: _}} =
             Directory.upsert_user(%{
               localpart: "tiny",
               password: "short"
             })
  end
end
