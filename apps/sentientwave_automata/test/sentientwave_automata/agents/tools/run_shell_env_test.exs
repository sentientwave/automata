defmodule SentientwaveAutomata.RunShellEnvTest do
  @moduledoc """
  Security regression tests: the LLM picks the shell command, so the command
  must not be able to read the pod's secret-bearing environment (SECRET_KEY_BASE,
  API tokens, LLM provider key) with a bare `printenv`.
  """
  use ExUnit.Case, async: false

  alias SentientwaveAutomata.Agents.Tools.RunShell

  setup do
    System.put_env("AUTOMATA_TEST_SECRET_VAR", "hunter2")

    on_exit(fn ->
      System.delete_env("AUTOMATA_TEST_SECRET_VAR")
      System.delete_env("AUTOMATA_RUN_SHELL_ENV")
    end)

    :ok
  end

  test "command sees a minimal default environment, not pod secrets" do
    {:ok, result} =
      RunShell.execute_direct(%{"command" => "printenv PATH", "cwd" => System.tmp_dir!()})

    assert result["exit_code"] == 0
    assert result["stdout"] =~ "/"

    {:ok, result} =
      RunShell.execute_direct(%{
        "command" => "printenv AUTOMATA_TEST_SECRET_VAR || echo HIDDEN",
        "cwd" => System.tmp_dir!()
      })

    assert result["exit_code"] == 0
    assert result["stdout"] =~ "HIDDEN"
  end

  test "AUTOMATA_RUN_SHELL_ENV allowlist exposes extra variables" do
    System.put_env("AUTOMATA_RUN_SHELL_ENV", "AUTOMATA_TEST_SECRET_VAR")

    {:ok, result} =
      RunShell.execute_direct(%{
        "command" => "printenv AUTOMATA_TEST_SECRET_VAR",
        "cwd" => System.tmp_dir!()
      })

    assert result["exit_code"] == 0
    assert result["stdout"] =~ "hunter2"
  end
end
