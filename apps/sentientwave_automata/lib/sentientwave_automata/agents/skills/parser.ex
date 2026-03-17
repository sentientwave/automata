defmodule SentientwaveAutomata.Agents.Skills.Parser do
  @moduledoc """
  Minimal markdown skill parser.
  """

  @spec parse(String.t()) :: {:ok, map()} | {:error, term()}
  def parse(markdown) when is_binary(markdown) do
    lines = String.split(markdown, "\n")

    name =
      lines
      |> Enum.find_value(fn
        "# Skill:" <> skill_name -> String.trim(skill_name)
        _ -> nil
      end)

    tools =
      lines
      |> Enum.filter(&String.starts_with?(String.trim(&1), "- "))
      |> Enum.map(&String.trim_leading(String.trim(&1), "- "))

    case name do
      nil -> {:error, :invalid_skill_markdown}
      _ -> {:ok, %{name: name, tools: tools, markdown_body: markdown}}
    end
  end
end
