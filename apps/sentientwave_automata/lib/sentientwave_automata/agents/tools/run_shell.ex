defmodule SentientwaveAutomata.Agents.Tools.RunShell do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  @impl true
  def name, do: "run_shell"

  @impl true
  def description do
    "Execute an arbitrary shell command in a requested folder and return stdout, stderr, and exit code."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "Shell command to execute"},
        "cwd" => %{"type" => "string", "description" => "Working directory path"}
      },
      "required" => ["command", "cwd"]
    }
  end

  @impl true
  def call(args, _opts \\ []) when is_map(args) do
    command = args |> Map.get("command", "") |> to_string() |> String.trim()
    cwd = args |> Map.get("cwd", "") |> to_string() |> String.trim()

    with :ok <- validate_command(command),
         :ok <- validate_cwd(cwd),
         {:ok, result} <- run(command, cwd) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(command, cwd) do
    nonce = Integer.to_string(System.unique_integer([:positive]))
    stdout_path = Path.join(System.tmp_dir!(), "automata_tool_stdout_#{nonce}.log")
    stderr_path = Path.join(System.tmp_dir!(), "automata_tool_stderr_#{nonce}.log")
    wrapped = "#{command} 1>#{escape_path(stdout_path)} 2>#{escape_path(stderr_path)}"

    result =
      try do
        {_output, exit_code} =
          System.cmd("/bin/sh", ["-lc", wrapped],
            cd: cwd,
            stderr_to_stdout: false,
            timeout: timeout_ms()
          )

        {:ok,
         %{
           "cwd" => cwd,
           "command" => command,
           "exit_code" => exit_code,
           "stdout" => read_file(stdout_path),
           "stderr" => read_file(stderr_path)
         }}
      rescue
        error ->
          {:error, {:run_shell_failed, Exception.message(error)}}
      catch
        :exit, reason ->
          {:error, {:run_shell_exit, inspect(reason)}}
      after
        _ = safe_rm(stdout_path)
        _ = safe_rm(stderr_path)
      end

    result
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp safe_rm(path), do: File.rm(path)

  defp validate_command(""), do: {:error, :missing_command}
  defp validate_command(_), do: :ok

  defp validate_cwd(""), do: {:error, :missing_cwd}

  defp validate_cwd(cwd) do
    case File.stat(cwd) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _} -> {:error, :cwd_not_directory}
      {:error, _} -> {:error, :cwd_not_found}
    end
  end

  defp escape_path(path) do
    "'" <> String.replace(path, "'", "'\"'\"'") <> "'"
  end

  defp timeout_ms do
    System.get_env("AUTOMATA_RUN_SHELL_TIMEOUT_MS", "120000")
    |> String.to_integer()
  rescue
    _ -> 120_000
  end
end
