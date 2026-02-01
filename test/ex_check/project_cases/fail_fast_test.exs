defmodule ExCheck.ProjectCases.FailFastTest do
  use ExCheck.ProjectCase, async: true

  test "--fail-fast terminates running tools early", %{project_dir: project_dir} do
    config_path = Path.join(project_dir, ".check.exs")

    File.write!(
      config_path,
      """
      [
        fail_fast: true,
        parallel: true,
        tools: [
          {:fail_tool, ["elixir", "-e", ":timer.sleep(150); IO.puts(\\"fail\\"); System.halt(1)"]},
          {:slow_tool, ["elixir", "-e", "IO.puts(\\"slow-start\\"); :timer.sleep(5000)"]}
        ]
      ]
      """
    )

    output =
      System.cmd("mix", ~w[check --only fail_tool --only slow_tool], cd: project_dir) |> cmd_exit(1)

    assert output =~ "fail_tool"
    assert output =~ "error code"

    assert output =~ "slow_tool"
    assert output =~ "terminated early"
    assert output =~ "SIGTERM"

    assert output =~ "=> output from"
    assert output =~ "slow_tool"
    assert output =~ "(terminated early)"
    assert output =~ "output may be incomplete"
  end

  test "--fail-fast marks tools as did not run on compiler failure", %{project_dir: project_dir} do
    invalid_file_path =
      project_dir
      |> Path.join("lib")
      |> Path.join("invalid.ex")

    File.write!(invalid_file_path, "defmodule Bad do\ndef oops( do\nend\n")

    output = System.cmd("mix", ~w[check --fail-fast], cd: project_dir) |> cmd_exit(1)

    assert output =~ "compiler"
    assert output =~ "did not run due to"
    assert output =~ "fail fast"
  end
end
