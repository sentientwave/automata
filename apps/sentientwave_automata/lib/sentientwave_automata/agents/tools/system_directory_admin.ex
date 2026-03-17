defmodule SentientwaveAutomata.Agents.Tools.SystemDirectoryAdmin do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.SynapseAdmin
  alias SentientwaveAutomata.Security.Passwords

  @impl true
  def name, do: "system_directory_admin"

  @impl true
  def description do
    "Control Automata and Matrix user directory: manage human accounts and virtually hire or fire agents."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => [
            "list_directory",
            "upsert_human",
            "remove_human",
            "hire_agent",
            "invite_to_room",
            "fire_agent"
          ]
        },
        "localpart" => %{"type" => "string"},
        "room_id" => %{"type" => "string"},
        "display_name" => %{"type" => "string"},
        "password" => %{"type" => "string"},
        "admin" => %{"type" => "boolean"}
      },
      "required" => ["action"]
    }
  end

  @impl true
  def call(args, _opts \\ []) when is_map(args) do
    action = args |> Map.get("action", "") |> to_string() |> String.trim()

    case action do
      "list_directory" ->
        {:ok, %{"users" => Directory.list_users(), "count" => length(Directory.list_users())}}

      "upsert_human" ->
        upsert_human(args)

      "remove_human" ->
        remove_human(args)

      "hire_agent" ->
        hire_agent(args)

      "invite_to_room" ->
        invite_to_room(args)

      "fire_agent" ->
        fire_agent(args)

      _ ->
        {:error, :unsupported_action}
    end
  end

  defp upsert_human(args) do
    localpart = normalize_localpart(Map.get(args, "localpart"))
    display_name = args |> Map.get("display_name", localpart) |> to_string() |> String.trim()
    {password, generated?} = resolve_password(localpart)
    admin = Map.get(args, "admin", false) in [true, "true", "1", 1, "on"]

    with :ok <- validate_localpart(localpart),
         :ok <- validate_password(password),
         {:ok, user} <-
           Directory.upsert_user(%{
             localpart: localpart,
             kind: :person,
             display_name: display_name,
             password: password,
             admin: admin
           }),
         :ok <- SynapseAdmin.reconcile_user(user) do
      {:ok, %{"result" => "human_upserted", "user" => user, "password_generated" => generated?}}
    end
  end

  defp remove_human(args) do
    localpart = normalize_localpart(Map.get(args, "localpart"))

    with :ok <- validate_localpart(localpart),
         :ok <- maybe_disallow_admin_removal(localpart) do
      :ok = Directory.delete_user(localpart)
      _ = SynapseAdmin.deactivate_user(localpart)
      {:ok, %{"result" => "human_removed", "localpart" => localpart}}
    end
  end

  defp hire_agent(args) do
    localpart = normalize_localpart(Map.get(args, "localpart"))

    display_name =
      args |> Map.get("display_name", "Agent #{localpart}") |> to_string() |> String.trim()

    {password, generated?} = resolve_password(localpart)

    with :ok <- validate_localpart(localpart),
         :ok <- validate_password(password),
         {:ok, directory_user} <-
           Directory.upsert_user(%{
             localpart: localpart,
             kind: :agent,
             display_name: display_name,
             password: password,
             admin: false
           }),
         :ok <- SynapseAdmin.reconcile_user(directory_user),
         {:ok, agent_profile} <-
           Agents.upsert_agent(%{
             slug: localpart,
             kind: :agent,
             display_name: display_name,
             matrix_localpart: localpart,
             status: :active,
             metadata: %{source: "system_directory_admin"}
           }),
         {:ok, wallet} <-
           Agents.upsert_agent_wallet(agent_profile.id, %{
             kind: "personal",
             status: "active",
             matrix_credentials: %{
               localpart: localpart,
               mxid: "@#{localpart}:#{System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")}",
               password: password,
               homeserver_url: System.get_env("MATRIX_URL", "http://localhost:8008")
             },
             metadata: %{source: "system_directory_admin", credential_rotated: generated?}
           }) do
      {:ok,
       %{
         "result" => "agent_hired",
         "directory_user" => directory_user,
         "agent_profile_id" => agent_profile.id,
         "wallet_id" => wallet.id,
         "password_generated" => generated?
       }}
    end
  end

  defp fire_agent(args) do
    localpart = normalize_localpart(Map.get(args, "localpart"))

    with :ok <- validate_localpart(localpart) do
      :ok = Directory.delete_user(localpart)
      _ = SynapseAdmin.deactivate_user(localpart)
      _ = disable_agent_profile(localpart)
      _ = disable_agent_wallet(localpart)
      {:ok, %{"result" => "agent_fired", "localpart" => localpart}}
    end
  end

  defp invite_to_room(args) do
    localpart = normalize_localpart(Map.get(args, "localpart"))
    room_id = args |> Map.get("room_id", "") |> to_string() |> String.trim()

    with :ok <- validate_localpart(localpart),
         :ok <- validate_room_id(room_id),
         %{} <- Directory.get_user(localpart) || {:error, :unknown_user},
         :ok <- SynapseAdmin.invite_localpart_to_room(localpart, room_id) do
      {:ok,
       %{
         "result" => "agent_invited",
         "localpart" => localpart,
         "room_id" => room_id
       }}
    end
  end

  defp disable_agent_profile(localpart) do
    case Agents.get_agent_by_localpart(localpart) do
      nil ->
        :ok

      profile ->
        _ =
          Agents.upsert_agent(%{
            slug: profile.slug,
            kind: profile.kind,
            display_name: profile.display_name,
            matrix_localpart: profile.matrix_localpart,
            status: :disabled,
            metadata: Map.put(profile.metadata || %{}, :fired_at, DateTime.utc_now())
          })

        :ok
    end
  end

  defp disable_agent_wallet(localpart) do
    case Agents.get_agent_by_localpart(localpart) do
      nil ->
        :ok

      profile ->
        case Agents.get_agent_wallet(profile.id) do
          nil ->
            :ok

          wallet ->
            _ =
              Agents.upsert_agent_wallet(profile.id, %{
                wallet_ref: wallet.wallet_ref,
                kind: wallet.kind,
                status: "disabled",
                balance: wallet.balance,
                matrix_credentials: wallet.matrix_credentials,
                metadata: Map.put(wallet.metadata || %{}, :fired_at, DateTime.utc_now())
              })

            :ok
        end
    end
  end

  defp maybe_disallow_admin_removal(localpart) do
    if localpart == System.get_env("MATRIX_ADMIN_USER", "admin"),
      do: {:error, :cannot_remove_primary_admin},
      else: :ok
  end

  defp resolve_password(localpart) do
    case Directory.get_user(localpart) do
      %{password: existing} when is_binary(existing) and byte_size(existing) >= 12 ->
        {existing, false}

      _ ->
        {Passwords.generate(password_length()), true}
    end
  end

  defp password_length do
    System.get_env("AUTOMATA_GENERATED_PASSWORD_LENGTH", "20")
    |> String.to_integer()
  rescue
    _ -> 20
  end

  defp validate_localpart(value) when is_binary(value) and value != "", do: :ok
  defp validate_localpart(_), do: {:error, :missing_localpart}

  defp validate_password(value) when is_binary(value) and byte_size(value) >= 12, do: :ok
  defp validate_password(_), do: {:error, :password_too_short}
  defp validate_room_id(value) when is_binary(value) and value != "", do: :ok
  defp validate_room_id(_), do: {:error, :missing_room_id}

  defp normalize_localpart(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split(":", parts: 2)
    |> List.first()
    |> String.downcase()
  end
end
