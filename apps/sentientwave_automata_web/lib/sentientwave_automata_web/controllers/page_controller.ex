defmodule SentientwaveAutomataWeb.PageController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.Matrix.Onboarding.Artifacts
  alias SentientwaveAutomata.Settings
  alias SentientwaveAutomata.System.Status
  alias SentientwaveAutomataWeb.AdminAuth

  @provider_options [
    {"Local (Fallback)", "local"},
    {"OpenAI", "openai"},
    {"OpenRouter", "openrouter"},
    {"LM Studio", "lm-studio"},
    {"Ollama", "ollama"}
  ]
  @tool_options [
    {"Brave Internet Search", "brave_search"},
    {"System Directory Admin", "system_directory_admin"},
    {"Run Shell", "run_shell"}
  ]

  def home(conn, _params), do: redirect(conn, to: ~p"/dashboard")

  def dashboard(conn, _params) do
    status = Status.summary()

    render(conn, :dashboard,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("dashboard")
    )
  end

  def onboarding(conn, params) do
    status = Status.summary()
    users_input = Map.get(params, "users", "")
    include_passwords = Map.get(params, "include_passwords", "false") in ["1", "true", "on"]

    artifacts =
      Artifacts.build(status, users_input: users_input, include_passwords: include_passwords)

    render(conn, :onboarding,
      status: status,
      artifacts: artifacts,
      admin_user: AdminAuth.expected_username(),
      nav: nav("onboarding")
    )
  end

  def llm(conn, _params) do
    render_llm(conn)
  end

  def new_llm_provider(conn, _params) do
    status = Status.summary()
    effective = Settings.llm_provider_effective()
    providers = Settings.list_llm_provider_configs()

    render(conn, :new_llm_provider,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("llm"),
      provider_options: @provider_options,
      llm: effective,
      providers: providers,
      token_configured?: token_configured?(effective.api_token),
      persisted?: effective.configured_in_db
    )
  end

  def llm_provider(conn, %{"id" => id}) do
    status = Status.summary()
    effective = Settings.llm_provider_effective()
    providers = Settings.list_llm_provider_configs()

    case Settings.get_llm_provider_config(id) do
      nil ->
        conn
        |> put_flash(:error, "Provider not found.")
        |> redirect(to: ~p"/settings/llm")

      provider ->
        render(conn, :llm_provider,
          status: status,
          admin_user: AdminAuth.expected_username(),
          nav: nav("llm"),
          provider_options: @provider_options,
          llm: effective,
          providers: providers,
          provider: provider,
          token_configured?: token_configured?(effective.api_token),
          persisted?: effective.configured_in_db
        )
    end
  end

  def tools(conn, _params) do
    render_tools(conn)
  end

  def new_tool(conn, _params) do
    status = Status.summary()
    tools = Settings.list_tool_configs()

    render(conn, :new_tool,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("tools"),
      tool_options: @tool_options,
      tools: tools
    )
  end

  def tool(conn, %{"id" => id}) do
    status = Status.summary()
    tools = Settings.list_tool_configs()

    case Settings.get_tool_config(id) do
      nil ->
        conn
        |> put_flash(:error, "Tool not found.")
        |> redirect(to: ~p"/settings/tools")

      tool ->
        render(conn, :tool,
          status: status,
          admin_user: AdminAuth.expected_username(),
          nav: nav("tools"),
          tool_options: @tool_options,
          tools: tools,
          tool: tool
        )
    end
  end

  def create_llm_provider(conn, %{"llm" => llm_params}) do
    attrs = sanitize_llm_params(llm_params)
    clear_api_token = truthy?(Map.get(llm_params, "clear_api_token", "false"))

    case Settings.create_llm_provider_config(attrs,
           preserve_existing_token: false,
           clear_api_token: clear_api_token
         ) do
      {:ok, _config} ->
        conn
        |> put_flash(:info, "LLM provider added.")
        |> redirect(to: ~p"/settings/llm")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not add LLM provider.")
        |> redirect(to: ~p"/settings/llm")
    end
  end

  def create_llm_provider(conn, _params) do
    conn
    |> put_flash(:error, "Invalid provider payload.")
    |> redirect(to: ~p"/settings/llm")
  end

  def update_llm_provider(conn, %{"id" => id, "llm" => llm_params}) do
    attrs = sanitize_llm_params(llm_params)
    clear_api_token = truthy?(Map.get(llm_params, "clear_api_token", "false"))

    case Settings.get_llm_provider_config(id) do
      nil ->
        conn
        |> put_flash(:error, "Provider not found.")
        |> redirect(to: ~p"/settings/llm")

      config ->
        case Settings.update_llm_provider_config(config, attrs,
               preserve_existing_token: true,
               clear_api_token: clear_api_token
             ) do
          {:ok, _updated} ->
            conn
            |> put_flash(:info, "LLM provider updated.")
            |> redirect(to: ~p"/settings/llm/providers/#{config.id}")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Could not update LLM provider.")
            |> redirect(to: ~p"/settings/llm/providers/#{config.id}")
        end
    end
  end

  def update_llm_provider(conn, _params) do
    conn
    |> put_flash(:error, "Invalid provider update payload.")
    |> redirect(to: ~p"/settings/llm")
  end

  def set_default_llm_provider(conn, %{"id" => id}) do
    case Settings.set_default_llm_provider(id) do
      :ok ->
        conn
        |> put_flash(:info, "Default LLM provider updated.")
        |> redirect(to: ~p"/settings/llm")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not set default provider.")
        |> redirect(to: ~p"/settings/llm")
    end
  end

  def delete_llm_provider(conn, %{"id" => id}) do
    case Settings.delete_llm_provider(id) do
      :ok ->
        conn
        |> put_flash(:info, "LLM provider removed.")
        |> redirect(to: ~p"/settings/llm")

      {:error, :cannot_delete_last_provider} ->
        conn
        |> put_flash(:error, "At least one LLM provider must remain configured.")
        |> redirect(to: ~p"/settings/llm")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not remove provider.")
        |> redirect(to: ~p"/settings/llm")
    end
  end

  def create_tool(conn, %{"tool" => tool_params}) do
    attrs = sanitize_tool_params(tool_params)
    clear_api_token = truthy?(Map.get(tool_params, "clear_api_token", "false"))

    case Settings.create_tool_config(attrs,
           preserve_existing_token: false,
           clear_api_token: clear_api_token
         ) do
      {:ok, _config} ->
        conn
        |> put_flash(:info, "Tool added.")
        |> redirect(to: ~p"/settings/tools")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not add tool.")
        |> redirect(to: ~p"/settings/tools")
    end
  end

  def create_tool(conn, _params) do
    conn
    |> put_flash(:error, "Invalid tool payload.")
    |> redirect(to: ~p"/settings/tools")
  end

  def update_tool(conn, %{"id" => id, "tool" => tool_params}) do
    attrs = sanitize_tool_params(tool_params)
    clear_api_token = truthy?(Map.get(tool_params, "clear_api_token", "false"))

    case Settings.get_tool_config(id) do
      nil ->
        conn
        |> put_flash(:error, "Tool not found.")
        |> redirect(to: ~p"/settings/tools")

      config ->
        case Settings.update_tool_config(config, attrs,
               preserve_existing_token: true,
               clear_api_token: clear_api_token
             ) do
          {:ok, _updated} ->
            conn
            |> put_flash(:info, "Tool updated.")
            |> redirect(to: ~p"/settings/tools/#{config.id}")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Could not update tool.")
            |> redirect(to: ~p"/settings/tools/#{config.id}")
        end
    end
  end

  def update_tool(conn, _params) do
    conn
    |> put_flash(:error, "Invalid tool update payload.")
    |> redirect(to: ~p"/settings/tools")
  end

  def delete_tool(conn, %{"id" => id}) do
    case Settings.delete_tool_config(id) do
      :ok ->
        conn
        |> put_flash(:info, "Tool removed.")
        |> redirect(to: ~p"/settings/tools")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not remove tool.")
        |> redirect(to: ~p"/settings/tools")
    end
  end

  defp render_llm(conn) do
    status = Status.summary()
    effective = Settings.llm_provider_effective()
    providers = Settings.list_llm_provider_configs()

    render(conn, :llm,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("llm"),
      provider_options: @provider_options,
      llm: effective,
      providers: providers,
      token_configured?: token_configured?(effective.api_token),
      persisted?: effective.configured_in_db
    )
  end

  defp render_tools(conn) do
    status = Status.summary()
    tools = Settings.list_tool_configs()

    render(conn, :tools,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("tools"),
      tool_options: @tool_options,
      tools: tools
    )
  end

  defp nav(active) do
    [
      %{id: "dashboard", label: "Dashboard", href: "/dashboard", active: active == "dashboard"},
      %{
        id: "onboarding",
        label: "Onboarding",
        href: "/onboarding",
        active: active == "onboarding"
      },
      %{id: "llm", label: "LLM Providers", href: "/settings/llm", active: active == "llm"},
      %{id: "tools", label: "Tools", href: "/settings/tools", active: active == "tools"}
    ]
  end

  defp sanitize_llm_params(params) do
    params
    |> Map.take([
      "name",
      "slug",
      "provider",
      "model",
      "base_url",
      "api_token",
      "enabled",
      "is_default",
      "timeout_seconds"
    ])
    |> Map.update("name", "Provider", &String.trim(to_string(&1)))
    |> Map.update("slug", "", &String.trim(to_string(&1)))
    |> Map.update("provider", "local", &normalize_provider/1)
    |> Map.update("model", "local-default", &String.trim(to_string(&1)))
    |> Map.update("base_url", "", &String.trim(to_string(&1)))
    |> Map.update("api_token", "", &String.trim(to_string(&1)))
    |> Map.update("enabled", true, &truthy?/1)
    |> Map.update("is_default", false, &truthy?/1)
    |> Map.update("timeout_seconds", 600, &normalize_timeout_seconds/1)
  end

  defp sanitize_tool_params(params) do
    params
    |> Map.take(["name", "slug", "tool_name", "base_url", "api_token", "enabled"])
    |> Map.update("name", "Brave Search", &String.trim(to_string(&1)))
    |> Map.update("slug", "", &String.trim(to_string(&1)))
    |> Map.update("tool_name", "brave_search", &normalize_tool_name/1)
    |> Map.update("base_url", "", &String.trim(to_string(&1)))
    |> Map.update("api_token", "", &String.trim(to_string(&1)))
    |> Map.update("enabled", true, &truthy?/1)
  end

  defp normalize_provider(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tool_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp normalize_timeout_seconds(value) when is_integer(value), do: clamp_timeout_seconds(value)

  defp normalize_timeout_seconds(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, _} -> clamp_timeout_seconds(seconds)
      :error -> 600
    end
  end

  defp normalize_timeout_seconds(_), do: 600

  defp clamp_timeout_seconds(seconds) when seconds < 1, do: 1
  defp clamp_timeout_seconds(seconds) when seconds > 3600, do: 3600
  defp clamp_timeout_seconds(seconds), do: seconds

  defp token_configured?(token) when is_binary(token), do: String.trim(token) != ""
  defp token_configured?(_), do: false
end
