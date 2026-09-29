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
  def call(args, opts \\ []) when is_map(args) do
    args = if Map.has_key?(args, "wait"), do: args, else: Map.put(args, "wait", true)
    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch("run_shell", args, opts, :shell_failed)
  end

  @doc "Direct (non-Temporal) execution used by org-ops activities and tests."
  def execute_direct(args, _opts \\ []) when is_map(args) do
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
        # Elixir >= 1.19 removed System.cmd's :timeout option, so the deadline
        # is enforced around the call (timeout surfaces as a caught exit).
        task =
          Task.async(fn ->
            # `env -i` gives exact-replacement semantics: Erlang's :env port
            # option only extends the inherited environment, so a bare
            # `printenv` would otherwise see every pod secret.
            System.cmd(
              "/usr/bin/env",
              ["-i" | env_assignments() ++ ["/bin/sh", "-lc", wrapped]],
              cd: cwd,
              stderr_to_stdout: false
            )
          end)

        {_output, exit_code} = Task.await(task, timeout_ms())

        {:ok,
         %{
           "cwd" => cwd,
           "command" => command,
           "exit_code" => exit_code,
           "stdout" => read_capped(stdout_path),
           "stderr" => read_capped(stderr_path)
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

  # Output is fed back into the LLM context: an unbounded dump ("cat huge.log",
  # "yes") would blow up the run. Keep head+tail around the truncation marker.
  @max_output_bytes 64 * 1024

  defp read_capped(path) do
    case File.read(path) do
      {:ok, content} -> cap(content)
      {:error, _} -> ""
    end
  end

  defp cap(content) when byte_size(content) <= @max_output_bytes, do: content

  defp cap(content) do
    keep = @max_output_bytes - 200
    head = binary_part(content, 0, keep - div(keep, 2))
    tail_start = byte_size(content) - div(keep, 2)
    tail = binary_part(content, tail_start, byte_size(content) - tail_start)

    head <>
      "\n\n[... output truncated, #{byte_size(content)} bytes total ...]\n\n" <> tail
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

  # The pod environment carries strong secrets (SECRET_KEY_BASE, API tokens,
  # the LLM provider key). The LLM picks the command, so it should not be able
  # to read them with a bare `printenv`; expose a minimal default set and let
  # deployments widen it via AUTOMATA_RUN_SHELL_ENV (comma-separated names).
  @default_shell_env ~w(PATH HOME USER LANG LC_ALL TZ)

  defp env_assignments do
    shell_env()
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
  end

  defp shell_env do
    allowlist =
      System.get_env("AUTOMATA_RUN_SHELL_ENV", "")
      |> String.split(",", trim: true)
      |> Enum.reject(&(&1 == ""))

    @default_shell_env
    |> Kernel.++(allowlist)
    |> Enum.uniq()
    |> Enum.filter(fn key -> System.get_env(key) != nil end)
    |> Enum.map(fn key -> {key, System.get_env(key)} end)
  end

  defp timeout_ms do
    System.get_env("AUTOMATA_RUN_SHELL_TIMEOUT_MS", "120000")
    |> String.to_integer()
  rescue
    _ -> 120_000
  end
end
