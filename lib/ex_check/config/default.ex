defmodule ExCheck.Config.Default do
  @moduledoc false

  # Default tool order tries to put short-running tools first in order for sequential output
  # streaming to display as many outputs as possible as soon as possible.
  #
  # By default, tools run in "quick" mode optimized for fast iteration:
  # - Compiler uses incremental compilation (no --force)
  # - Tests run only stale tests (--stale)
  # - Credo checks only git-changed files
  # - Some tools (unused_deps, mix_audit, sobelow) are skipped
  #
  # Use --full flag to run comprehensive checks (all tools, full commands).
  @curated_tools [
    {:compiler, "mix compile --warnings-as-errors",
     full: "mix compile --warnings-as-errors --force"},
    {:unused_deps, "mix deps.unlock --check-unused",
     detect: [{:elixir, ">= 1.10.0"}], fix: "mix deps.unlock --unused", full_only: true},
    {:formatter, "mix format --check-formatted",
     detect: [{:file, ".formatter.exs"}], fix: "mix format"},
    {:mix_audit, "mix deps.audit", detect: [{:package, :mix_audit}], full_only: true},
    {:credo, "mix credo", detect: [{:package, :credo}], git_changed: true},
    {:doctor, "mix doctor", detect: [{:package, :doctor}, {:elixir, ">= 1.8.0"}]},
    {:sobelow, "mix sobelow --exit", umbrella: [recursive: true],
     detect: [{:package, :sobelow}], full_only: true},
    {:ex_doc, "mix docs", detect: [{:package, :ex_doc}]},
    {:ex_unit, "mix test --stale", detect: [{:file, "test"}],
     retry: "mix test --failed", full: "mix test"},
    {:dialyzer, "mix dialyzer", detect: [{:package, :dialyxir}]},
    {:gettext, "mix gettext.extract --check-up-to-date",
     detect: [{:package, :gettext}], deps: [:ex_unit]},
    {:npm_test, "npm test", cd: "assets", detect: [{:file, "package.json", else: :disable}]}
  ]

  @default_config [
    parallel: true,
    skipped: true,
    tools: @curated_tools
  ]

  def get do
    @default_config
  end

  def tool_order(tool) do
    Enum.find_index(@curated_tools, &(elem(&1, 0) == tool))
  end
end
