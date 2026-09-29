defmodule SentientwaveAutomata.Agents.Tools.CreateMatrixRoom do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  alias SentientwaveAutomata.Agents.Activities
  alias SentientwaveAutomata.Matrix.SynapseAdmin

  @impl true
  def name, do: "create_matrix_room"

  @impl true
  def description do
    "Create a new Matrix room (e.g. for a project or working group) with a name, topic, " <>
      "and invited colleagues. Returns the new room_id. The office reader joins automatically."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "Room name"},
        "topic" => %{"type" => "string", "description" => "Room topic (mission/purpose)"},
        "invite" => %{
          "type" => "array",
          "description" => "Localparts of colleagues to invite (e.g. [\"jane.doe\"])",
          "items" => %{"type" => "string"}
        }
      },
      "required" => ["name"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    args = if Map.has_key?(args, "wait"), do: args, else: Map.put(args, "wait", true)

    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch(
      "create_matrix_room",
      args,
      opts,
      :create_failed
    )
  end

  @doc """
  Direct (non-Temporal) execution used by org-ops activities.
  """
  def execute_direct(args, opts \\ []) when is_map(args) do
    agent_id = Keyword.get(opts, :agent_id)
    name = args |> Map.get("name", "") |> to_string() |> String.trim()
    topic = args |> Map.get("topic", "") |> to_string() |> String.trim()
    invite = args |> Map.get("invite", []) |> List.wrap()

    cond do
      name == "" ->
        {:error, :missing_room_name}

      is_nil(agent_id) ->
        {:error, :missing_agent_context}

      true ->
        with {:ok, credentials} <- agent_credentials(agent_id),
             {:ok, room_id} <-
               matrix_adapter().create_room(credentials, %{
                 "name" => name,
                 "topic" => topic,
                 "invite" => invite
               }) do
          # join the invitees and the office reader (best-effort)
          participants =
            invite ++
              if(reader = safe_reader_localpart(), do: [reader], else: [])

          _ =
            safe_establish_membership(credentials, room_id, Enum.uniq(participants))

          {:ok, %{"status" => "created", "room_id" => room_id, "name" => name, "topic" => topic}}
        end
    end
  end

  defp agent_credentials(agent_id) do
    case Activities.agent_post_credentials(agent_id) do
      %{} = credentials -> {:ok, credentials}
      nil -> {:error, :no_agent_wallet}
    end
  end

  defp safe_establish_membership(credentials, room_id, participants) do
    creator = credentials |> Map.get("localpart") |> to_string() |> String.trim()

    if creator != "" and participants != [] do
      SynapseAdmin.establish_direct_room_membership(creator, room_id, participants)
    else
      :ok
    end
  rescue
    _ -> {:error, :membership_unavailable}
  end

  defp safe_reader_localpart do
    matrix_adapter().reader_localpart()
  rescue
    _ -> nil
  end

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end
end

defmodule SentientwaveAutomata.Agents.Tools.DeleteMatrixRoom do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  alias SentientwaveAutomata.Matrix.SynapseAdmin

  @impl true
  def name, do: "delete_matrix_room"

  @impl true
  def description do
    "Delete (and purge) a Matrix room by room_id. Destructive — only use for rooms that " <>
      "must be removed permanently."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "room_id" => %{
          "type" => "string",
          "description" => "The room id to delete (e.g. !abc123:localhost)"
        }
      },
      "required" => ["room_id"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    args = if Map.has_key?(args, "wait"), do: args, else: Map.put(args, "wait", true)

    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch(
      "delete_matrix_room",
      args,
      opts,
      :delete_failed
    )
  end

  @doc """
  Direct (non-Temporal) execution used by org-ops activities.
  """
  def execute_direct(args, _opts \\ []) when is_map(args) do
    room_id = args |> Map.get("room_id", "") |> to_string() |> String.trim()

    if room_id == "" do
      {:error, :missing_room_id}
    else
      case SynapseAdmin.delete_room(room_id) do
        :ok -> {:ok, %{"status" => "deleted", "room_id" => room_id}}
        {:error, reason} -> {:error, {:delete_failed, reason}}
      end
    end
  end
end
