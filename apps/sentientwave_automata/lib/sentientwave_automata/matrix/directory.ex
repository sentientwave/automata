defmodule SentientwaveAutomata.Matrix.Directory do
  @moduledoc """
  Internal directory of people and agent identities managed by Automata.
  """

  use GenServer

  @type user :: %{
          id: String.t(),
          localpart: String.t(),
          kind: :person | :agent,
          display_name: String.t(),
          password: String.t(),
          admin: boolean()
        }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec list_users() :: [user()]
  def list_users, do: GenServer.call(__MODULE__, :list)

  @spec get_user(String.t()) :: user() | nil
  def get_user(localpart), do: GenServer.call(__MODULE__, {:get, localpart})

  @spec upsert_user(map()) :: {:ok, user()} | {:error, map()}
  def upsert_user(attrs), do: GenServer.call(__MODULE__, {:upsert, attrs})

  @spec delete_user(String.t()) :: :ok
  def delete_user(localpart), do: GenServer.call(__MODULE__, {:delete, localpart})

  @impl true
  def init(_state) do
    {:ok, seed_users()}
  end

  @impl true
  def handle_call(:list, _from, users) do
    {:reply, users |> Map.values() |> Enum.sort_by(& &1.localpart), users}
  end

  def handle_call({:get, localpart}, _from, users) do
    key = localpart |> to_string() |> String.trim() |> normalize_localpart()
    {:reply, Map.get(users, key), users}
  end

  def handle_call({:upsert, attrs}, _from, users) do
    case normalize_user(attrs) do
      {:ok, user} ->
        {:reply, {:ok, user}, Map.put(users, user.localpart, user)}

      {:error, reason} ->
        {:reply, {:error, reason}, users}
    end
  end

  def handle_call({:delete, localpart}, _from, users) do
    {:reply, :ok, Map.delete(users, String.trim(to_string(localpart)))}
  end

  defp seed_users do
    admin_localpart = System.get_env("MATRIX_ADMIN_USER", "admin")
    admin_password = System.get_env("MATRIX_ADMIN_PASSWORD", "")
    invite_password = System.get_env("MATRIX_INVITE_PASSWORD", "")
    invite_users = split_env_users("MATRIX_INVITE_USERS")
    agent_users = split_env_users("AUTOMATA_AGENT_USERS", "automata")
    agent_password = System.get_env("AUTOMATA_AGENT_PASSWORD", invite_password)

    seeded =
      [
        %{
          id: "person:#{admin_localpart}",
          localpart: normalize_localpart(admin_localpart),
          kind: :person,
          display_name: "Admin #{admin_localpart}",
          password: admin_password,
          admin: true
        }
      ] ++
        Enum.map(invite_users, fn user ->
          %{
            id: "person:#{normalize_localpart(user)}",
            localpart: normalize_localpart(user),
            kind: :person,
            display_name: normalize_localpart(user),
            password: invite_password,
            admin: false
          }
        end) ++
        Enum.map(agent_users, fn user ->
          %{
            id: "agent:#{normalize_localpart(user)}",
            localpart: normalize_localpart(user),
            kind: :agent,
            display_name: "Agent #{normalize_localpart(user)}",
            password: agent_password,
            admin: false
          }
        end)

    seeded
    |> Enum.reject(&(&1.localpart == ""))
    |> Enum.reduce(%{}, fn user, acc -> Map.put(acc, user.localpart, user) end)
  end

  defp split_env_users(key, default_value \\ "") do
    key
    |> System.get_env(default_value)
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_user(attrs) do
    localpart =
      attrs |> Map.get("localpart", Map.get(attrs, :localpart, "")) |> normalize_localpart()

    display_name =
      attrs |> Map.get("display_name", Map.get(attrs, :display_name, localpart)) |> to_string()

    password = attrs |> Map.get("password", Map.get(attrs, :password, "")) |> to_string()
    kind = attrs |> Map.get("kind", Map.get(attrs, :kind, "person")) |> normalize_kind()
    admin = attrs |> Map.get("admin", Map.get(attrs, :admin, false)) |> truthy?()

    cond do
      localpart == "" ->
        {:error, %{localpart: "is required"}}

      byte_size(password) < 8 ->
        {:error, %{password: "must be at least 8 characters"}}

      true ->
        {:ok,
         %{
           id: "#{Atom.to_string(kind)}:#{localpart}",
           localpart: localpart,
           kind: kind,
           display_name: display_name,
           password: password,
           admin: admin
         }}
    end
  end

  defp normalize_localpart(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp normalize_kind(value) when value in [:person, "person"], do: :person
  defp normalize_kind(value) when value in [:agent, "agent"], do: :agent
  defp normalize_kind(_), do: :person

  defp truthy?(value), do: value in [true, "true", "1", 1, "on"]
end
