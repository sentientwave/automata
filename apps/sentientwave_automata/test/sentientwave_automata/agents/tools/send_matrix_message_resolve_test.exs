defmodule SentientwaveAutomata.Agents.Tools.SendMatrixMessageResolveTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents.Tools.SendMatrixMessage
  alias SentientwaveAutomata.Matrix.Directory

  setup do
    _ =
      Directory.upsert_user(
        %{
          localpart: "jane.doe",
          kind: :agent,
          display_name: "Jane Doe",
          password: "password-12345",
          admin: false,
          metadata: %{}
        },
        seed: true
      )

    %{}
  end

  test "resolves an exact localpart" do
    assert SendMatrixMessage.resolve_recipient("jane.doe") == {:ok, "jane.doe"}
    assert SendMatrixMessage.resolve_recipient("@jane.doe:localhost") == {:ok, "jane.doe"}
  end

  test "resolves a first name to a localpart" do
    assert SendMatrixMessage.resolve_recipient("jane") == {:ok, "jane.doe"}
    assert SendMatrixMessage.resolve_recipient("Jane") == {:ok, "jane.doe"}
  end

  test "resolves a full display name" do
    assert SendMatrixMessage.resolve_recipient("Jane Doe") == {:ok, "jane.doe"}
  end

  test "rejects unknown recipients" do
    assert {:error, {:unknown_recipient, "nobody"}} =
             SendMatrixMessage.resolve_recipient("nobody")
  end

  test "empty recipient resolves to empty" do
    assert SendMatrixMessage.resolve_recipient("") == {:ok, ""}
  end
end
