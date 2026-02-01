defmodule ExCheck.UmbrellaProjectCases.FailFastTest do
  use ExCheck.UmbrellaProjectCase, async: true

  test "--fail-fast stops umbrella tools", %{project_dirs: [project_root_dir | _]} do
    config_path = Path.join(project_root_dir, ".check.exs")

    File.write!(
      config_path,
      """
      [
        parallel: true,
        fail_fast: true,
        tools: [
          {:fail_tool, ["elixir", "-e", ":timer.sleep(150); System.halt(1)"], umbrella: [recursive: false]},
          {:slow_tool, ["elixir", "-e", ":timer.sleep(5000)"], umbrella: [recursive: false]}
        ]
      ]
      """
    )

    assert File.exists?(config_path)

    output =
      System.cmd("mix", ~w[check --only fail_tool --only slow_tool], cd: project_root_dir) |> cmd_exit(1)

    assert output =~ "fail_tool"
    assert output =~ "error code"

    assert output =~ "slow_tool"
    assert output =~ "terminated early"
    assert output =~ "SIGTERM"
  end
end
