defmodule SentientwaveAutomata.SettingsTest do
  use SentientwaveAutomata.DataCase, async: true

  alias SentientwaveAutomata.Settings

  test "supports multiple provider configs and effective default selection" do
    assert {:ok, p1} =
             Settings.create_llm_provider_config(%{
               "name" => "OpenAI Primary",
               "slug" => "openai-primary",
               "provider" => "openai",
               "model" => "gpt-5.4",
               "api_token" => "tok_1",
               "enabled" => true,
               "is_default" => true
             })

    assert {:ok, _p2} =
             Settings.create_llm_provider_config(%{
               "name" => "Ollama Local",
               "slug" => "ollama-local",
               "provider" => "ollama",
               "model" => "llama3.1",
               "base_url" => "http://127.0.0.1:11434",
               "enabled" => true
             })

    assert length(Settings.list_llm_provider_configs()) == 2
    assert Settings.llm_provider_effective().id == p1.id
    assert Settings.llm_provider_effective().timeout_seconds == 600
    assert :ok = Settings.set_default_llm_provider(p1.id)
  end

  test "accepts anthropic provider configs" do
    assert {:ok, provider} =
             Settings.create_llm_provider_config(%{
               "name" => "Anthropic Primary",
               "slug" => "anthropic-primary",
               "provider" => "anthropic",
               "model" => "claude-sonnet-4-6",
               "base_url" => "https://api.anthropic.com",
               "api_token" => "sk-ant-test",
               "enabled" => true
             })

    assert provider.provider == "anthropic"
    assert provider.model == "claude-sonnet-4-6"
    assert provider.timeout_seconds == 600
  end

  test "accepts cerebras provider configs" do
    assert {:ok, provider} =
             Settings.create_llm_provider_config(%{
               "name" => "Cerebras Primary",
               "slug" => "cerebras-primary",
               "provider" => "cerebras",
               "model" => "gpt-oss-120b",
               "base_url" => "https://api.cerebras.ai/v1",
               "api_token" => "cs_test_key",
               "enabled" => true
             })

    assert provider.provider == "cerebras"
    assert provider.model == "gpt-oss-120b"
    assert provider.timeout_seconds == 600
  end

  test "accepts gemini provider configs" do
    assert {:ok, provider} =
             Settings.create_llm_provider_config(%{
               "name" => "Gemini Primary",
               "slug" => "gemini-primary",
               "provider" => "gemini",
               "model" => "gemini-3.1-pro-preview",
               "base_url" => "https://generativelanguage.googleapis.com/v1beta",
               "api_token" => "gemini_test_key",
               "enabled" => true
             })

    assert provider.provider == "gemini"
    assert provider.model == "gemini-3.1-pro-preview"
    assert provider.timeout_seconds == 600
  end

  test "cannot delete last provider" do
    assert {:ok, provider} =
             Settings.create_llm_provider_config(%{
               "name" => "Only Provider",
               "provider" => "local",
               "model" => "local-default",
               "enabled" => true,
               "is_default" => true
             })

    assert {:error, :cannot_delete_last_provider} = Settings.delete_llm_provider(provider.id)
  end

  test "creates and updates tool config" do
    assert {:ok, tool} =
             Settings.create_tool_config(%{
               "name" => "Brave Search",
               "tool_name" => "brave_search",
               "base_url" => "https://api.search.brave.com",
               "api_token" => "brv_key",
               "enabled" => true
             })

    assert is_binary(tool.id)
    assert length(Settings.list_tool_configs()) >= 1

    assert {:ok, updated} =
             Settings.update_tool_config(tool, %{
               "name" => "Brave Search Prod",
               "enabled" => false
             })

    assert updated.name == "Brave Search Prod"
    assert updated.enabled == false
  end
end
