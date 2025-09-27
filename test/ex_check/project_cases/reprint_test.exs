defmodule ExCheck.ProjectCases.ReprintTest do
  use ExCheck.ProjectCase, async: true

  test "--no-reprint suppresses reprinting", %{project_dir: project_dir} do
    invalid_file_path =
      project_dir
      |> Path.join("lib")
      |> Path.join("invalid.ex")

    File.write!(invalid_file_path, "IO.inspect( 1 )")

    output = System.cmd("mix", ~w[check --no-reprint], cd: project_dir) |> cmd_exit(1)

    refute output =~ "=> reprinting errors"
    assert output =~ "formatter error code"
  end

  test "config disables reprinting", %{project_dir: project_dir} do
    config_path = Path.join(project_dir, ".check.exs")

    File.write!(
      config_path,
      """
      [
        fix: false,
        reprint: false
      ]
      """
    )

    invalid_file_path =
      project_dir
      |> Path.join("lib")
      |> Path.join("invalid.ex")

    File.write!(invalid_file_path, "IO.inspect( 1 )")

    output = System.cmd("mix", ~w[check], cd: project_dir) |> cmd_exit(1)

    refute output =~ "=> reprinting errors"
    assert output =~ "formatter error code"
  end
end
