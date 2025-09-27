defmodule ExCheck.ProjectCases.FailFastTest do
  use ExCheck.ProjectCase, async: true

  test "--fail-fast stops after first failure", %{project_dir: project_dir} do
    invalid_file_path =
      project_dir
      |> Path.join("lib")
      |> Path.join("invalid.ex")

    File.write!(invalid_file_path, "IO.inspect( 1 )")

    output = System.cmd("mix", ~w[check --fail-fast], cd: project_dir) |> cmd_exit(1)

    assert output =~ "formatter error code"
    refute output =~ "ex_unit success"
    assert output =~ "ex_unit skipped due to not finished"
  end

  test "config fail_fast stops after first failure", %{project_dir: project_dir} do
    config_path = Path.join(project_dir, ".check.exs")

    File.write!(
      config_path,
      """
      [
        fix: false,
        fail_fast: true
      ]
      """
    )

    invalid_file_path =
      project_dir
      |> Path.join("lib")
      |> Path.join("invalid.ex")

    File.write!(invalid_file_path, "IO.inspect( 1 )")

    output = System.cmd("mix", ~w[check], cd: project_dir) |> cmd_exit(1)

    assert output =~ "formatter error code"
    refute output =~ "ex_unit success"
    assert output =~ "ex_unit skipped due to not finished"
  end
end
