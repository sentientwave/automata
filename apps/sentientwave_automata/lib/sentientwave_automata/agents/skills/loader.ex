defmodule SentientwaveAutomata.Agents.Skills.Loader do
  @moduledoc """
  Loads markdown skill files from the configured skills directory.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Skills.Parser

  @spec sync_agent_skills(SentientwaveAutomata.Agents.AgentProfile.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync_agent_skills(agent) do
    skills_path =
      Application.get_env(:sentientwave_automata, :agent_skills_path, "skills")
      |> Path.join(agent.slug)

    if File.dir?(skills_path) do
      files = Path.wildcard(Path.join(skills_path, "*.md"))

      count =
        Enum.reduce(files, 0, fn file_path, acc ->
          with {:ok, markdown} <- File.read(file_path),
               {:ok, parsed} <- Parser.parse(markdown),
               {:ok, _skill} <-
                 Agents.upsert_skill(%{
                   agent_id: agent.id,
                   name: parsed.name,
                   markdown_path: file_path,
                   markdown_body: markdown,
                   version: "v1",
                   metadata: %{tools: parsed.tools}
                 }) do
            acc + 1
          else
            _ -> acc
          end
        end)

      {:ok, count}
    else
      {:ok, 0}
    end
  end
end
