defmodule SentientwaveAutomata.Settings do
  @moduledoc """
  Runtime settings persisted in Postgres.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Repo
  alias SentientwaveAutomata.Settings.LLMProviderConfig
  alias SentientwaveAutomata.Settings.ToolConfig

  @singleton_key "default"
  @llm_provider_defaults %{
    "local" => %{model: "local-default", base_url: ""},
    "openai" => %{model: "gpt-5.4", base_url: "https://api.openai.com/v1"},
    "gemini" => %{
      model: "gemini-3.1-pro-preview",
      base_url: "https://generativelanguage.googleapis.com/v1beta"
    },
    "anthropic" => %{model: "claude-sonnet-4-6", base_url: "https://api.anthropic.com"},
    "cerebras" => %{model: "gpt-oss-120b", base_url: "https://api.cerebras.ai/v1"},
    "openrouter" => %{model: "openrouter/auto", base_url: "https://openrouter.ai/api/v1"},
    "lm-studio" => %{model: "local-model", base_url: "http://host.containers.internal:1234/v1"},
    "ollama" => %{model: "llama3.1", base_url: "http://host.containers.internal:11434"}
  }

  @spec list_llm_provider_configs() :: [LLMProviderConfig.t()]
  def list_llm_provider_configs do
    Repo.all(from c in LLMProviderConfig, order_by: [desc: c.is_default, asc: c.inserted_at])
  rescue
    _ -> []
  end

  @spec get_llm_provider_config(binary()) :: LLMProviderConfig.t() | nil
  def get_llm_provider_config(id), do: Repo.get(LLMProviderConfig, id)

  @spec get_default_llm_provider_config() :: LLMProviderConfig.t() | nil
  def get_default_llm_provider_config do
    Repo.one(
      from c in LLMProviderConfig, where: c.is_default == true and c.enabled == true, limit: 1
    ) ||
      Repo.one(
        from c in LLMProviderConfig,
          where: c.enabled == true,
          order_by: [asc: c.inserted_at],
          limit: 1
      )
  rescue
    _ -> nil
  end

  @spec llm_provider_effective() :: map()
  def llm_provider_effective do
    config = get_default_llm_provider_config()
    env_provider = System.get_env("AUTOMATA_LLM_PROVIDER", "local")
    provider = config_value(config, :provider, env_provider)
    defaults = llm_provider_defaults(provider)

    %{
      id: config_field(config, :id),
      name: config_value(config, :name, "Environment"),
      slug: config_value(config, :slug, "environment"),
      provider: provider,
      model: config_value(config, :model, System.get_env("AUTOMATA_LLM_MODEL", defaults.model)),
      base_url:
        config_value(
          config,
          :base_url,
          System.get_env("AUTOMATA_LLM_API_BASE", defaults.base_url)
        ),
      api_token: config_value(config, :api_token, System.get_env("AUTOMATA_LLM_API_KEY", "")),
      timeout_seconds: config_int_value(config, :timeout_seconds, default_llm_timeout_seconds()),
      configured_in_db: is_struct(config, LLMProviderConfig)
    }
  end

  @spec create_llm_provider_config(map(), keyword()) ::
          {:ok, LLMProviderConfig.t()} | {:error, Ecto.Changeset.t()}
  def create_llm_provider_config(attrs, opts \\ []) when is_map(attrs) do
    preserve_existing_token = Keyword.get(opts, :preserve_existing_token, false)
    clear_api_token = Keyword.get(opts, :clear_api_token, false)
    attrs = normalize_provider_attrs(attrs)

    Repo.transaction(fn ->
      attrs = maybe_preserve_token(attrs, nil, preserve_existing_token, clear_api_token)

      attrs =
        if attrs["is_default"] do
          Repo.update_all(LLMProviderConfig, set: [is_default: false])
          attrs
        else
          attrs
        end

      %LLMProviderConfig{singleton_key: @singleton_key}
      |> LLMProviderConfig.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, config} ->
          ensure_at_least_one_default!()
          config

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> unwrap_transaction()
  end

  @spec update_llm_provider_config(LLMProviderConfig.t(), map(), keyword()) ::
          {:ok, LLMProviderConfig.t()} | {:error, Ecto.Changeset.t()}
  def update_llm_provider_config(%LLMProviderConfig{} = config, attrs, opts \\ [])
      when is_map(attrs) do
    preserve_existing_token = Keyword.get(opts, :preserve_existing_token, true)
    clear_api_token = Keyword.get(opts, :clear_api_token, false)
    attrs = normalize_provider_attrs(attrs)

    Repo.transaction(fn ->
      attrs = maybe_preserve_token(attrs, config, preserve_existing_token, clear_api_token)

      if attrs["is_default"] do
        Repo.update_all(LLMProviderConfig, set: [is_default: false])
      end

      config
      |> LLMProviderConfig.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          ensure_at_least_one_default!()
          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> unwrap_transaction()
  end

  @spec set_default_llm_provider(binary()) :: :ok | {:error, term()}
  def set_default_llm_provider(id) when is_binary(id) do
    Repo.transaction(fn ->
      case Repo.get(LLMProviderConfig, id) do
        nil ->
          Repo.rollback(:not_found)

        config ->
          Repo.update_all(LLMProviderConfig, set: [is_default: false])

          case config
               |> LLMProviderConfig.changeset(%{"is_default" => true, "enabled" => true})
               |> Repo.update() do
            {:ok, _} -> :ok
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete_llm_provider(binary()) :: :ok | {:error, term()}
  def delete_llm_provider(id) when is_binary(id) do
    Repo.transaction(fn ->
      providers = list_llm_provider_configs()

      if length(providers) <= 1 do
        Repo.rollback(:cannot_delete_last_provider)
      end

      case Repo.get(LLMProviderConfig, id) do
        nil ->
          Repo.rollback(:not_found)

        config ->
          is_default = config.is_default
          :ok = Repo.delete!(config) && :ok

          if is_default do
            ensure_at_least_one_default!()
          end

          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_default_provider_from_env() :: :ok
  def ensure_default_provider_from_env do
    if list_llm_provider_configs() == [] do
      env_provider = System.get_env("AUTOMATA_LLM_PROVIDER", "local")
      defaults = llm_provider_defaults(env_provider)

      _ =
        create_llm_provider_config(%{
          "name" => "Primary",
          "slug" => "primary",
          "provider" => env_provider,
          "model" => System.get_env("AUTOMATA_LLM_MODEL", defaults.model),
          "base_url" => System.get_env("AUTOMATA_LLM_API_BASE", defaults.base_url),
          "api_token" => System.get_env("AUTOMATA_LLM_API_KEY", ""),
          "timeout_seconds" => default_llm_timeout_seconds(),
          "enabled" => true,
          "is_default" => true
        })

      :ok
    else
      ensure_at_least_one_default!()
      :ok
    end
  end

  @spec list_tool_configs() :: [ToolConfig.t()]
  def list_tool_configs do
    Repo.all(from c in ToolConfig, order_by: [asc: c.inserted_at])
  rescue
    _ -> []
  end

  @spec list_enabled_tool_configs() :: [ToolConfig.t()]
  def list_enabled_tool_configs do
    Repo.all(from c in ToolConfig, where: c.enabled == true, order_by: [asc: c.inserted_at])
  rescue
    _ -> []
  end

  @spec get_tool_config(binary()) :: ToolConfig.t() | nil
  def get_tool_config(id), do: Repo.get(ToolConfig, id)

  @spec create_tool_config(map(), keyword()) ::
          {:ok, ToolConfig.t()} | {:error, Ecto.Changeset.t()}
  def create_tool_config(attrs, opts \\ []) when is_map(attrs) do
    preserve_existing_token = Keyword.get(opts, :preserve_existing_token, false)
    clear_api_token = Keyword.get(opts, :clear_api_token, false)
    attrs = normalize_tool_attrs(attrs)
    attrs = maybe_preserve_tool_token(attrs, nil, preserve_existing_token, clear_api_token)

    %ToolConfig{}
    |> ToolConfig.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_tool_config(ToolConfig.t(), map(), keyword()) ::
          {:ok, ToolConfig.t()} | {:error, Ecto.Changeset.t()}
  def update_tool_config(%ToolConfig{} = config, attrs, opts \\ []) when is_map(attrs) do
    preserve_existing_token = Keyword.get(opts, :preserve_existing_token, true)
    clear_api_token = Keyword.get(opts, :clear_api_token, false)
    attrs = normalize_tool_attrs(attrs)
    attrs = maybe_preserve_tool_token(attrs, config, preserve_existing_token, clear_api_token)

    config
    |> ToolConfig.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_tool_config(binary()) :: :ok | {:error, term()}
  def delete_tool_config(id) when is_binary(id) do
    case Repo.get(ToolConfig, id) do
      nil ->
        {:error, :not_found}

      config ->
        case Repo.delete(config) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec ensure_default_tools_from_env() :: :ok
  def ensure_default_tools_from_env do
    _ =
      ensure_tool_config(%{
        "name" => "Brave Search",
        "slug" => "brave-search",
        "tool_name" => "brave_search",
        "base_url" => System.get_env("AUTOMATA_BRAVE_BASE_URL", "https://api.search.brave.com"),
        "api_token" => System.get_env("AUTOMATA_BRAVE_API_KEY", ""),
        "enabled" => true
      })

    _ =
      ensure_tool_config(%{
        "name" => "System Directory Admin",
        "slug" => "system-directory-admin",
        "tool_name" => "system_directory_admin",
        "base_url" => "",
        "api_token" => "",
        "enabled" => true
      })

    _ =
      ensure_tool_config(%{
        "name" => "Run Shell",
        "slug" => "run-shell",
        "tool_name" => "run_shell",
        "base_url" => "",
        "api_token" => "",
        "enabled" => true
      })

    :ok
  end

  defp ensure_at_least_one_default! do
    has_default =
      Repo.exists?(
        from c in LLMProviderConfig,
          where: c.is_default == true and c.enabled == true
      )

    if has_default do
      :ok
    else
      case Repo.one(
             from c in LLMProviderConfig,
               where: c.enabled == true,
               order_by: [asc: c.inserted_at],
               limit: 1
           ) do
        nil ->
          :ok

        config ->
          _ =
            config
            |> LLMProviderConfig.changeset(%{"is_default" => true})
            |> Repo.update()

          :ok
      end
    end
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp normalize_provider_attrs(attrs) do
    provider =
      attrs
      |> Map.get("provider", "local")
      |> normalize_provider()

    defaults = llm_provider_defaults(provider)

    attrs
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
    |> Map.update("name", "Primary", &String.trim(to_string(&1)))
    |> Map.update("slug", "", &String.trim(to_string(&1)))
    |> Map.put("provider", provider)
    |> Map.update("model", defaults.model, &default_provider_field(&1, defaults.model))
    |> Map.update("base_url", defaults.base_url, &default_provider_field(&1, defaults.base_url))
    |> Map.update("api_token", "", &String.trim(to_string(&1)))
    |> Map.update("enabled", true, &truthy?/1)
    |> Map.update("is_default", false, &truthy?/1)
    |> Map.update("timeout_seconds", default_llm_timeout_seconds(), &normalize_timeout_seconds/1)
    |> ensure_default_slug()
  end

  @spec llm_provider_defaults(String.t() | atom() | nil) :: %{
          model: String.t(),
          base_url: String.t()
        }
  def llm_provider_defaults(provider) do
    provider
    |> normalize_provider()
    |> then(&Map.get(@llm_provider_defaults, &1, @llm_provider_defaults["local"]))
  end

  defp ensure_default_slug(attrs) do
    case Map.get(attrs, "slug", "") do
      "" ->
        Map.put(attrs, "slug", slugify(Map.get(attrs, "name", "provider")))

      _ ->
        attrs
    end
  end

  defp maybe_preserve_token(attrs, _current, _preserve, true), do: Map.put(attrs, "api_token", "")

  defp maybe_preserve_token(attrs, current, true, false)
       when not is_nil(current) and is_binary(current.api_token) and current.api_token != "" do
    if blank?(Map.get(attrs, "api_token")),
      do: Map.put(attrs, "api_token", current.api_token),
      else: attrs
  end

  defp maybe_preserve_token(attrs, _current, _preserve, _clear), do: attrs

  defp normalize_tool_attrs(attrs) do
    attrs
    |> Map.take(["name", "slug", "tool_name", "base_url", "api_token", "enabled"])
    |> Map.update("name", "Brave Search", &String.trim(to_string(&1)))
    |> Map.update("slug", "", &String.trim(to_string(&1)))
    |> Map.update("tool_name", "brave_search", &normalize_tool_name/1)
    |> Map.update("base_url", "", &String.trim(to_string(&1)))
    |> Map.update("api_token", "", &String.trim(to_string(&1)))
    |> Map.update("enabled", true, &truthy?/1)
    |> ensure_default_tool_slug()
  end

  defp ensure_default_tool_slug(attrs) do
    case Map.get(attrs, "slug", "") do
      "" ->
        Map.put(attrs, "slug", slugify(Map.get(attrs, "name", "tool")))

      _ ->
        attrs
    end
  end

  defp maybe_preserve_tool_token(attrs, _current, _preserve, true),
    do: Map.put(attrs, "api_token", "")

  defp maybe_preserve_tool_token(attrs, current, true, false)
       when not is_nil(current) and is_binary(current.api_token) and current.api_token != "" do
    if blank?(Map.get(attrs, "api_token")),
      do: Map.put(attrs, "api_token", current.api_token),
      else: attrs
  end

  defp maybe_preserve_tool_token(attrs, _current, _preserve, _clear), do: attrs

  defp config_field(nil, _field), do: nil
  defp config_field(config, field), do: Map.get(config, field)

  defp config_value(nil, _field, fallback), do: fallback

  defp config_value(config, field, fallback) do
    case Map.get(config, field) do
      value when is_binary(value) and value != "" -> value
      _ -> fallback
    end
  end

  defp config_int_value(nil, _field, fallback), do: fallback

  defp config_int_value(config, field, fallback) do
    case Map.get(config, field) do
      value when is_integer(value) and value > 0 -> value
      _ -> fallback
    end
  end

  defp normalize_provider(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp default_provider_field(value, fallback) do
    case value |> to_string() |> String.trim() do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp normalize_tool_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp ensure_tool_config(attrs) do
    slug = Map.get(attrs, "slug", "")

    case Repo.get_by(ToolConfig, slug: slug) do
      nil ->
        create_tool_config(attrs)

      _existing ->
        {:ok, :already_exists}
    end
  end

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/^-+|-+$/u, "")
    |> case do
      "" -> "provider"
      slug -> slug
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp normalize_timeout_seconds(value) when is_integer(value), do: clamp_timeout_seconds(value)

  defp normalize_timeout_seconds(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        default_llm_timeout_seconds()

      trimmed ->
        case Integer.parse(trimmed) do
          {seconds, _} -> clamp_timeout_seconds(seconds)
          :error -> default_llm_timeout_seconds()
        end
    end
  end

  defp normalize_timeout_seconds(_), do: default_llm_timeout_seconds()

  defp clamp_timeout_seconds(seconds) when seconds < 1, do: 1
  defp clamp_timeout_seconds(seconds) when seconds > 3600, do: 3600
  defp clamp_timeout_seconds(seconds), do: seconds

  defp default_llm_timeout_seconds do
    cond do
      timeout = parse_positive_int(System.get_env("AUTOMATA_LLM_TIMEOUT_SECONDS", "")) ->
        clamp_timeout_seconds(timeout)

      timeout_ms = parse_positive_int(System.get_env("AUTOMATA_LLM_TIMEOUT_MS", "")) ->
        timeout_ms
        |> Kernel./(1000)
        |> Float.ceil()
        |> trunc()
        |> clamp_timeout_seconds()

      true ->
        600
    end
  end

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_int(_), do: nil

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
