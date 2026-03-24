defmodule SentientwaveAutomata.Agents.LLM.Client do
  @moduledoc """
  Abstracted LLM inference client with provider selection via runtime config/env.
  """

  require Logger
  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.DeepResearch
  alias SentientwaveAutomata.Agents.LLM.TraceRecorder
  alias SentientwaveAutomata.Agents.Runtime
  alias SentientwaveAutomata.Agents.Tools.Executor
  alias SentientwaveAutomata.Settings

  @max_reply_chars 4_000

  @spec generate_response(keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_response(opts) do
    with {:ok, plan} <- plan_tool_calls(opts) do
      case Map.get(plan, :tool_calls, []) do
        [] ->
          generate_response_without_tools(opts)

        tool_calls ->
          case execute_tool_calls(Keyword.get(opts, :agent_id), tool_calls) do
            {:ok, tool_context} when tool_context != [] ->
              synthesize_tool_response(opts, tool_context)

            _ ->
              generate_response_without_tools(opts)
          end
      end
    else
      {:error, reason} ->
        Logger.warning("llm_provider_error reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec generate_response_without_tools(keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_response_without_tools(opts) do
    %{messages: messages, provider_opts: provider_opts, provider: provider} = response_state(opts)

    with {:ok, module} <- provider_module(provider),
         {:ok, text} <- traced_complete(module, messages, provider_opts, "response", 0),
         text when is_binary(text) and text != "" <- sanitize_text(text) do
      {:ok, text}
    else
      {:error, reason} ->
        Logger.warning("llm_provider_error provider=#{provider} reason=#{inspect(reason)}")
        {:error, reason}

      _ ->
        {:error, :empty_llm_response}
    end
  end

  @spec plan_tool_calls(keyword()) ::
          {:ok, %{tool_calls: [map()], available_tools: [map()]}} | {:error, term()}
  def plan_tool_calls(opts) do
    %{
      messages: base_messages,
      provider_opts: provider_opts,
      provider: provider,
      user_input: user_input,
      agent_id: agent_id
    } = state = response_state(opts)

    available_tools = Executor.available_tools(agent_id)

    cond do
      available_tools == [] ->
        {:ok, %{tool_calls: [], available_tools: []}}

      true ->
        with {:ok, module} <- provider_module(provider),
             {:ok, tool_calls} <-
               plan_with_heuristics_or_model(
                 module,
                 base_messages,
                 user_input,
                 available_tools,
                 provider_opts
               ) do
          {:ok, %{tool_calls: tool_calls, available_tools: available_tools, state: state}}
        end
    end
  end

  @spec execute_tool_calls(binary() | nil, [map()]) :: {:ok, [map()]} | {:error, term()}
  def execute_tool_calls(agent_id, tool_calls) when is_list(tool_calls) do
    available_tools = Executor.available_tools(agent_id)
    execute_tool_plan(tool_calls, available_tools)
  end

  @spec synthesize_tool_response(keyword(), [map()]) :: {:ok, String.t()} | {:error, term()}
  def synthesize_tool_response(opts, tool_context) when is_list(tool_context) do
    if tool_context == [] do
      generate_response_without_tools(opts)
    else
      %{
        messages: base_messages,
        provider_opts: provider_opts,
        provider: provider
      } = response_state(opts)

      tool_result_messages = [
        %{
          "role" => "system",
          "content" =>
            "Tool execution results are available for your reasoning. " <>
              "Do not mention internal tool names, JSON payloads, IDs, or workflow internals in the user-facing response. " <>
              "Summarize the outcome in plain language.\n\n#{Jason.encode!(%{"tool_results" => tool_context})}"
        }
      ]

      with {:ok, module} <- provider_module(provider),
           {:ok, text} <-
             traced_complete(
               module,
               base_messages ++ tool_result_messages,
               provider_opts,
               "tool_response",
               1
             ),
           text when is_binary(text) and text != "" <- sanitize_text(text) do
        {:ok, text}
      else
        _ -> generate_response_without_tools(opts)
      end
    end
  end

  @spec deep_research_decision(keyword()) :: map()
  def deep_research_decision(opts) when is_list(opts) do
    user_input =
      Keyword.get(opts, :user_input, "")
      |> to_string()
      |> String.trim()

    available_tools =
      Keyword.get(opts, :available_tools) ||
        Executor.available_tools(Keyword.get(opts, :agent_id))

    explicit? = explicit_deep_research?(opts)
    fallback = DeepResearch.fallback_decision(user_input, available_tools)

    cond do
      not DeepResearch.should_consider?(user_input, available_tools) and not explicit? ->
        fallback

      true ->
        %{
          messages: base_messages,
          provider_opts: provider_opts,
          provider: provider
        } = response_state(opts)

        with {:ok, module} <- provider_module(provider),
             {:ok, response} <-
               traced_complete(
                 module,
                 base_messages ++
                   [deep_research_decision_message(available_tools, explicit?)],
                 provider_opts,
                 "deep_research_decision",
                 0
               ),
             {:ok, payload} <- extract_json_object(response) do
          DeepResearch.normalize_decision(payload, user_input, available_tools)
        else
          _ -> fallback
        end
    end
  end

  @spec review_deep_research_round(keyword(), map()) :: {:ok, map()} | {:error, term()}
  def review_deep_research_round(opts, round_payload)
      when is_list(opts) and is_map(round_payload) do
    %{
      messages: base_messages,
      provider_opts: provider_opts,
      provider: provider
    } = response_state(opts)

    evidence = Map.get(round_payload, "evidence", [])
    round_index = normalize_round_index(Map.get(round_payload, "round_index"))
    max_rounds = normalize_max_rounds(Map.get(round_payload, "max_rounds"))
    prior_summary = Map.get(round_payload, "prior_summary", "")

    fallback =
      DeepResearch.normalize_round_review(%{}, evidence, round_index, max_rounds)

    with {:ok, module} <- provider_module(provider),
         {:ok, response} <-
           traced_complete(
             module,
             base_messages ++
               [
                 deep_research_review_message(
                   evidence,
                   prior_summary,
                   round_index,
                   max_rounds
                 )
               ],
             provider_opts,
             "deep_research_review",
             round_index
           ),
         {:ok, payload} <- extract_json_object(response) do
      {:ok, DeepResearch.normalize_round_review(payload, evidence, round_index, max_rounds)}
    else
      _ -> {:ok, fallback}
    end
  end

  @spec synthesize_deep_research_response(keyword(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def synthesize_deep_research_response(opts, research_payload)
      when is_list(opts) and is_map(research_payload) do
    %{
      messages: base_messages,
      provider_opts: provider_opts,
      provider: provider
    } = response_state(opts)

    with {:ok, module} <- provider_module(provider),
         {:ok, text} <-
           traced_complete(
             module,
             base_messages ++ [deep_research_result_message(research_payload)],
             provider_opts,
             "deep_research_response",
             0
           ),
         text when is_binary(text) and text != "" <- sanitize_text(text) do
      {:ok, text}
    else
      {:error, reason} ->
        Logger.warning(
          "deep_research_response_failed provider=#{provider} reason=#{inspect(reason)}"
        )

        {:error, reason}

      _ ->
        {:error, :empty_llm_response}
    end
  end

  defp provider_module("openai"), do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.OpenAI}

  defp provider_module("openrouter"),
    do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.OpenRouter}

  defp provider_module("anthropic"),
    do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.Anthropic}

  defp provider_module("gemini"),
    do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.Gemini}

  defp provider_module("cerebras"),
    do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.Cerebras}

  defp provider_module("lm-studio"), do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.LMStudio}
  defp provider_module("ollama"), do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.Ollama}
  defp provider_module("local"), do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.Local}
  defp provider_module(other), do: {:error, {:unsupported_llm_provider, other}}

  defp sanitize_text(text) do
    text
    |> String.trim()
    |> String.slice(0, @max_reply_chars)
  end

  defp constitution_messages(prompt_text) when is_binary(prompt_text) do
    trimmed = String.trim(prompt_text)

    if trimmed == "" do
      []
    else
      [
        %{
          "role" => "system",
          "content" =>
            "Company constitution and governance laws.\n\n" <>
              "These rules are binding for all reasoning, planning, and tool use.\n\n" <>
              trimmed
        }
      ]
    end
  end

  defp constitution_messages(_), do: []

  defp plan_with_heuristics_or_model(module, base_messages, user_input, available_tools, opts) do
    with {:ok, plan} <- heuristic_tool_plan(user_input, available_tools, opts),
         true <- plan != [] do
      {:ok, plan}
    else
      false ->
        run_model_tool_planner(module, base_messages, user_input, available_tools, opts)

      {:error, _reason} ->
        run_model_tool_planner(module, base_messages, user_input, available_tools, opts)
    end
  end

  defp run_model_tool_planner(module, base_messages, user_input, available_tools, opts) do
    with {:ok, tool_plan_text} <-
           traced_complete(
             module,
             base_messages ++ [tool_planner_message(available_tools)],
             opts,
             "tool_planner",
             0
           ),
         {:ok, plan} <-
           parse_or_infer_tool_plan(tool_plan_text, user_input, available_tools, opts) do
      {:ok, plan}
    else
      _ -> {:ok, []}
    end
  end

  defp response_state(opts) do
    effective = Settings.llm_provider_effective()
    agent_slug = Keyword.get(opts, :agent_slug, "automata")
    user_input = Keyword.get(opts, :user_input, "") |> to_string() |> String.trim()
    provider = Keyword.get(opts, :provider, effective.provider)
    model = Keyword.get(opts, :model, effective.model)
    timeout_seconds = Keyword.get(opts, :timeout_seconds, effective.timeout_seconds || 600)
    agent_id = Keyword.get(opts, :agent_id)
    context_text = Keyword.get(opts, :context_text, "") |> to_string() |> String.trim()
    trace_context = Keyword.get(opts, :trace_context, %{})
    constitution_snapshot = Keyword.get(opts, :constitution_snapshot)

    constitution_prompt_text =
      Keyword.get(opts, :constitution_prompt_text) ||
        Runtime.constitution_prompt_text(constitution_snapshot)

    provider_opts =
      [
        model: model,
        timeout_seconds: timeout_seconds,
        agent_id: agent_id,
        user_input: user_input,
        room_id: Keyword.get(opts, :room_id)
      ]
      |> maybe_put_provider_opt(:base_url, effective.base_url)
      |> maybe_put_provider_opt(:api_key, effective.api_token)
      |> Keyword.put(:trace_context, trace_context)
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:provider_config_id, effective.id)

    messages =
      [
        %{
          "role" => "system",
          "content" => system_prompt(agent_slug)
        }
      ] ++
        constitution_messages(constitution_prompt_text) ++
        skill_messages(agent_id) ++
        context_messages(context_text) ++
        [%{"role" => "user", "content" => user_prompt(user_input)}]

    %{
      provider: provider,
      provider_opts: provider_opts,
      messages: messages,
      user_input: user_input,
      agent_id: agent_id
    }
  end

  defp traced_complete(module, messages, opts, call_kind, sequence_index) do
    call_meta = %{
      agent_id: Keyword.get(opts, :agent_id),
      provider: Keyword.get(opts, :provider),
      provider_config_id: Keyword.get(opts, :provider_config_id),
      model: Keyword.get(opts, :model),
      base_url: Keyword.get(opts, :base_url),
      timeout_seconds: Keyword.get(opts, :timeout_seconds),
      trace_context: Keyword.get(opts, :trace_context, %{}),
      messages: messages,
      call_kind: call_kind,
      sequence_index: sequence_index
    }

    TraceRecorder.record_completion(call_meta, fn ->
      module.complete(
        messages,
        Keyword.drop(opts, [:trace_context, :provider, :provider_config_id])
      )
    end)
  end

  defp maybe_put_provider_opt(opts, _key, value) when value in [nil, ""], do: opts

  defp maybe_put_provider_opt(opts, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> opts
      trimmed -> Keyword.put(opts, key, trimmed)
    end
  end

  defp maybe_put_provider_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp tool_planner_message(available_tools) do
    %{
      "role" => "system",
      "content" =>
        "Tool calling is available. " <>
          "If a tool is needed, respond ONLY as JSON with shape " <>
          "{\"tool_calls\":[{\"name\":\"tool_name\",\"arguments\":{}}]}. " <>
          "If no tools are needed, respond ONLY with {\"tool_calls\":[]}. " <>
          "Available tools: #{inspect(tool_specs(available_tools))}"
    }
  end

  defp deep_research_decision_message(available_tools, explicit?) do
    limits = DeepResearch.config()
    tool_names = Enum.map(available_tools, &(Map.get(&1, :name) || Map.get(&1, "name")))

    %{
      "role" => "system",
      "content" =>
        "Decide whether this request requires deep research. " <>
          "Deep research is appropriate when the user explicitly asks for it or when the task needs fresh external evidence, comparison, investigation, or multi-step synthesis. " <>
          "Return ONLY JSON with keys enabled, reason, max_rounds, queries, and focus_areas. " <>
          "Set max_rounds between 1 and #{limits["max_rounds"]}. " <>
          "Keep queries to #{limits["max_queries_per_round"]} or fewer short web-search queries. " <>
          "Available tools: #{inspect(tool_names)}. " <>
          if(explicit?,
            do: "The user explicitly requested deeper research. Bias toward enabled=true.",
            else: ""
          )
    }
  end

  defp deep_research_review_message(evidence, prior_summary, round_index, max_rounds) do
    evidence_text = DeepResearch.render_evidence_for_prompt(evidence)
    limits = DeepResearch.config()

    %{
      "role" => "system",
      "content" =>
        "Review the current deep research evidence and decide whether more research is needed. " <>
          "Return ONLY JSON with keys round_summary, key_findings, continue_research, follow_up_queries, and top_sources. " <>
          "Keep follow_up_queries to #{limits["max_queries_per_round"]} or fewer. " <>
          "Only continue when the evidence is still incomplete and the next round will materially improve the answer. " <>
          "This is round #{round_index} of #{max_rounds}.\n\n" <>
          "Prior summary:\n#{blank_if_empty(prior_summary)}\n\n" <>
          "Current evidence:\n#{blank_if_empty(evidence_text)}"
    }
  end

  defp deep_research_result_message(research_payload) do
    %{
      "role" => "system",
      "content" =>
        "Deep research findings are available for your final answer. " <>
          "Write a plain-text response for the user. Do not use markdown bullets, JSON, or internal workflow language. " <>
          "Use the gathered evidence, mention uncertainty when sources disagree, and prefer concise paragraphs.\n\n" <>
          Jason.encode!(%{"deep_research" => research_payload})
    }
  end

  defp tool_specs(tools) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    end)
  end

  defp parse_or_infer_tool_plan(text, user_input, available_tools, opts) do
    case parse_tool_plan(text) do
      {:ok, calls} ->
        {:ok, calls}

      _ ->
        heuristic_tool_plan(user_input, available_tools, opts)
    end
  end

  defp parse_tool_plan(text) when is_binary(text) do
    trimmed = String.trim(text)

    candidate =
      case Jason.decode(trimmed) do
        {:ok, payload} ->
          {:ok, payload}

        _ ->
          extract_json_object(trimmed)
      end

    with {:ok, payload} <- candidate,
         calls when is_list(calls) <- Map.get(payload, "tool_calls", []) do
      {:ok, calls}
    else
      _ -> {:error, :invalid_tool_plan}
    end
  end

  defp execute_tool_plan(tool_calls, available_tools) do
    tool_calls
    |> Enum.take(2)
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, acc} ->
      tool_name = call |> Map.get("name", "") |> to_string()
      args = Map.get(call, "arguments", %{})

      case Executor.execute(tool_name, args, available_tools) do
        {:ok, result} ->
          {:cont, {:ok, [%{"name" => tool_name, "result" => result} | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp heuristic_tool_plan(user_input, available_tools, opts) do
    input = String.downcase(user_input)
    room_id = opts |> Keyword.get(:room_id, "") |> to_string() |> String.trim()

    cond do
      tool_available?(available_tools, "system_directory_admin") and
        String.match?(input, ~r/\b(hire|onboard|add agent)\b/) and
        String.match?(input, ~r/\b(invite)\b/) and room_id != "" ->
        localpart = extract_name_localpart(user_input, "agent", "assistant")

        {:ok,
         [
           %{
             "name" => "system_directory_admin",
             "arguments" => %{"action" => "hire_agent", "localpart" => localpart}
           },
           %{
             "name" => "system_directory_admin",
             "arguments" => %{
               "action" => "invite_to_room",
               "localpart" => localpart,
               "room_id" => room_id
             }
           }
         ]}

      tool_available?(available_tools, "system_directory_admin") and
          String.match?(input, ~r/\b(hire|onboard|add agent)\b/) ->
        localpart = extract_name_localpart(user_input, "agent", "assistant")

        {:ok,
         [
           %{
             "name" => "system_directory_admin",
             "arguments" => %{"action" => "hire_agent", "localpart" => localpart}
           }
         ]}

      tool_available?(available_tools, "system_directory_admin") and
        String.match?(input, ~r/\b(invite)\b/) and room_id != "" ->
        localpart = extract_name_localpart(user_input, "agent", "user")

        {:ok,
         [
           %{
             "name" => "system_directory_admin",
             "arguments" => %{
               "action" => "invite_to_room",
               "localpart" => localpart,
               "room_id" => room_id
             }
           }
         ]}

      tool_available?(available_tools, "system_directory_admin") and
          String.match?(input, ~r/\b(fire|remove agent|disable agent)\b/) ->
        localpart = extract_name_localpart(user_input, "agent", "")

        {:ok,
         [
           %{
             "name" => "system_directory_admin",
             "arguments" => %{"action" => "fire_agent", "localpart" => localpart}
           }
         ]}

      tool_available?(available_tools, "system_directory_admin") and
          String.match?(input, ~r/\b(add user|create user|invite user|hire human)\b/) ->
        localpart = extract_name_localpart(user_input, "user", "human")

        {:ok,
         [
           %{
             "name" => "system_directory_admin",
             "arguments" => %{"action" => "upsert_human", "localpart" => localpart}
           }
         ]}

      tool_available?(available_tools, "run_shell") and
          String.match?(input, ~r/\b(weather|forecast|temperature)\b/) ->
        location = extract_weather_location(user_input)
        command = "curl -fsS \"https://wttr.in/#{URI.encode_www_form(location)}?format=3\""

        {:ok, [%{"name" => "run_shell", "arguments" => %{"command" => command, "cwd" => "/tmp"}}]}

      tool_available?(available_tools, "run_shell") and
          String.match?(input, ~r/\b(run|execute|shell|command)\b/) ->
        case extract_shell_command_and_cwd(user_input) do
          {:ok, command, cwd} ->
            {:ok,
             [%{"name" => "run_shell", "arguments" => %{"command" => command, "cwd" => cwd}}]}

          :error ->
            {:ok, []}
        end

      true ->
        {:ok, []}
    end
  end

  defp tool_available?(tools, name), do: Enum.any?(tools, &(&1.name == name))

  defp extract_name_localpart(input, anchor1, anchor2) do
    pattern =
      case String.trim(anchor2) do
        "" -> ~r/(?:#{anchor1}\s+)([a-zA-Z0-9._-]+)/i
        _ -> ~r/(?:#{anchor1}|#{anchor2})\s+(?:agent\s+)?([a-zA-Z0-9._-]+)/i
      end

    case Regex.run(pattern, input, capture: :all_but_first) do
      [name] -> slugify(name)
      _ -> "new-agent"
    end
  end

  defp extract_shell_command_and_cwd(input) do
    with [command] <- Regex.run(~r/(?:run|execute)\s+`([^`]+)`/i, input, capture: :all_but_first),
         [cwd] <- Regex.run(~r/(?:in|at)\s+([~\/\w\-.]+)/i, input, capture: :all_but_first) do
      {:ok, String.trim(command), String.trim(cwd)}
    else
      _ -> :error
    end
  end

  defp extract_weather_location(input) do
    case Regex.run(~r/\b(?:in|for|at)\s+([a-zA-Z][a-zA-Z\s\-]{1,60})/i, input,
           capture: :all_but_first
         ) do
      [location] ->
        location
        |> String.trim()
        |> String.replace(~r/\s+/, " ")

      _ ->
        "San Diego"
    end
  end

  defp extract_json_object(text) do
    case Regex.run(~r/\{[\s\S]*\}/u, text) do
      [json] -> Jason.decode(json)
      _ -> {:error, :no_json_object}
    end
  end

  defp explicit_deep_research?(opts) do
    Keyword.get(opts, :deep_research) in [true, "true", "1"] or
      Keyword.get(opts, :research_mode) in [:deep, "deep", "deep_research"]
  end

  defp normalize_round_index(value) when is_integer(value) and value > 0, do: value

  defp normalize_round_index(value) do
    case Integer.parse(to_string(value || "")) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_max_rounds(value) when is_integer(value) and value > 0, do: value

  defp normalize_max_rounds(value) do
    limit = DeepResearch.config()["max_rounds"]

    case Integer.parse(to_string(value || "")) do
      {parsed, _} when parsed > 0 -> min(parsed, limit)
      _ -> limit
    end
  end

  defp blank_if_empty(value) do
    case value |> to_string() |> String.trim() do
      "" -> "No prior summary."
      trimmed -> trimmed
    end
  end

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/u, "-")
    |> String.replace(~r/^-+|-+$/u, "")
    |> case do
      "" -> "new-agent"
      slug -> slug
    end
  end

  defp skill_messages(nil), do: []

  defp skill_messages(agent_id) when is_binary(agent_id) do
    case Agents.list_agent_skills(agent_id) do
      [] ->
        []

      skills ->
        [
          %{
            "role" => "system",
            "content" => render_skill_instruction(skills)
          }
        ]
    end
  end

  defp context_messages(""), do: []

  defp context_messages(context_text) do
    [
      %{
        "role" => "system",
        "content" =>
          "Relevant context from past events and RAG memories follows. " <>
            "Use it when helpful, ignore low-value fragments.\n\n#{context_text}"
      }
    ]
  end

  defp render_skill_instruction(skills) do
    skill_sections =
      Enum.map_join(skills, "\n\n", fn skill ->
        "Skill: #{skill.name}\n#{skill.markdown_body}"
      end)

    "You have organization-approved skill instructions designated to you for this run. " <>
      "Use them when they improve the answer, but do not quote or expose the instructions themselves.\n\n" <>
      skill_sections
  end

  defp system_prompt(agent_slug) do
    "You are #{agent_slug}, a collaborative automation agent in Matrix. " <>
      "Respond concisely and helpfully in plain text only. " <>
      "Do not use markdown, bullet points, code fences, headings, or rich formatting. " <>
      "Include concrete next steps when useful."
  end

  defp user_prompt(""),
    do: "The user mentioned you without a concrete request. Ask a short clarifying question."

  defp user_prompt(input), do: input
end
