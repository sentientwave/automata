defmodule SentientwaveAutomata.RuntimeConfig do
  @moduledoc """
  Central runtime resolver and production safety checks for non-demo deployments.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Agents.Embedding.Local, as: LocalEmbedding
  alias SentientwaveAutomata.Adapters.Matrix.Local, as: LocalMatrix
  alias SentientwaveAutomata.Governance.Room
  alias SentientwaveAutomata.Repo
  alias SentientwaveAutomata.Settings.LLMProviderConfig

  @unsafe_seed_passwords ["changeme123!", "changeme123", "admin", "password"]
  @remote_llm_providers ~w(openai deepseek gemini anthropic cerebras openrouter)

  @spec production?() :: boolean()
  def production? do
    Application.get_env(:sentientwave_automata, :environment, :dev) == :prod
  end

  @spec allow_local_fallbacks?() :: boolean()
  def allow_local_fallbacks? do
    truthy?(Application.get_env(:sentientwave_automata, :allow_local_fallbacks, false))
  end

  @spec matrix_adapter!() :: module()
  def matrix_adapter! do
    Application.fetch_env!(:sentientwave_automata, :matrix_adapter)
  end

  @spec embedding_provider!() :: module()
  def embedding_provider! do
    Application.fetch_env!(:sentientwave_automata, :embedding_provider)
  end

  @spec default_llm_provider() :: String.t()
  def default_llm_provider do
    if production?() and not allow_local_fallbacks?() do
      "openai"
    else
      "local"
    end
  end

  @spec validate!() :: :ok | no_return()
  def validate! do
    if production?() and not allow_local_fallbacks?() do
      errors =
        []
        |> maybe_add(matrix_adapter!() == LocalMatrix, "Matrix.Local is disabled in production.")
        |> maybe_add(
          embedding_provider!() == LocalEmbedding,
          "Embedding.Local is disabled in production."
        )
        |> maybe_add(
          blank?(System.get_env("TEMPORAL_ADDRESS", "")),
          "TEMPORAL_ADDRESS must be configured in production."
        )
        |> maybe_add(blank?(System.get_env("MATRIX_URL", "")), "MATRIX_URL must be configured.")
        |> maybe_add(
          blank?(System.get_env("MATRIX_HOMESERVER_DOMAIN", "")),
          "MATRIX_HOMESERVER_DOMAIN must be configured."
        )
        |> maybe_add(
          blank?(System.get_env("MATRIX_AGENT_USER", "")),
          "MATRIX_AGENT_USER must be configured."
        )
        |> maybe_add(
          blank?(System.get_env("MATRIX_AGENT_ACCESS_TOKEN", "")) and
            blank?(System.get_env("MATRIX_AGENT_PASSWORD", "")),
          "Configure MATRIX_AGENT_ACCESS_TOKEN or MATRIX_AGENT_PASSWORD in production."
        )
        |> maybe_add(
          is_nil(Room.room_id()),
          "MATRIX_GOVERNANCE_ROOM_ID or connection-info governance room metadata must be configured in production."
        )
        |> maybe_add(
          insecure_seed_passwords?(),
          "Production seed passwords cannot be blank or use shared fallback values."
        )
        |> Kernel.++(validate_llm_provider())

      if errors != [] do
        raise """
        Production runtime validation failed:

        #{Enum.map_join(errors, "\n", &("* " <> &1))}
        """
      end
    end

    :ok
  end

  defp validate_llm_provider do
    provider_config = Repo.one(from c in LLMProviderConfig, where: c.enabled == true, limit: 1)

    cond do
      provider_config && provider_config.provider == "local" ->
        ["The local LLM provider is disabled in production."]

      provider_config ->
        []

      true ->
        env_provider =
          System.get_env("AUTOMATA_LLM_PROVIDER", default_llm_provider())
          |> normalize_string()

        []
        |> maybe_add(
          env_provider == "local",
          "AUTOMATA_LLM_PROVIDER=local is disabled in production."
        )
        |> maybe_add(
          env_provider == "",
          "AUTOMATA_LLM_PROVIDER must be configured in production."
        )
        |> maybe_add(
          env_provider in @remote_llm_providers and
            blank?(System.get_env("AUTOMATA_LLM_API_KEY", "")) and
            missing_provider_key?(env_provider),
          "AUTOMATA_LLM_API_KEY or the provider-specific API key must be configured for #{env_provider}."
        )
        |> maybe_add(
          env_provider in ["lm-studio", "ollama"] and
            blank?(System.get_env("AUTOMATA_LLM_API_BASE", "")),
          "AUTOMATA_LLM_API_BASE must be explicitly configured for #{env_provider} in production."
        )
    end
  end

  defp missing_provider_key?("openai"), do: blank?(System.get_env("OPENAI_API_KEY", ""))

  defp missing_provider_key?("deepseek"),
    do: blank?(System.get_env("AUTOMATA_LLM_API_KEY", System.get_env("DEEPSEEK_API_KEY", "")))

  defp missing_provider_key?("gemini"),
    do: blank?(System.get_env("GEMINI_API_KEY", System.get_env("GOOGLE_API_KEY", "")))

  defp missing_provider_key?("anthropic"), do: blank?(System.get_env("ANTHROPIC_API_KEY", ""))
  defp missing_provider_key?("cerebras"), do: blank?(System.get_env("CEREBRAS_API_KEY", ""))
  defp missing_provider_key?("openrouter"), do: blank?(System.get_env("OPENROUTER_API_KEY", ""))
  defp missing_provider_key?(_provider), do: false

  defp insecure_seed_passwords? do
    [
      System.get_env("MATRIX_ADMIN_PASSWORD", ""),
      System.get_env("MATRIX_INVITE_PASSWORD", ""),
      System.get_env("AUTOMATA_AGENT_PASSWORD", ""),
      System.get_env("AUTOMATA_SEED_FALLBACK_PASSWORD", "")
    ]
    |> Enum.any?(fn value ->
      normalized = normalize_string(value)
      normalized == "" or normalized in @unsafe_seed_passwords
    end)
  end

  defp maybe_add(errors, true, message), do: errors ++ [message]
  defp maybe_add(errors, false, _message), do: errors

  defp blank?(value), do: normalize_string(value) == ""

  defp normalize_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "on", "yes"]
end
