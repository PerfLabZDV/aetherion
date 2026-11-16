defmodule Mix.Tasks.Aetherion do
  @shortdoc "Runs a PerfLang test suite"
  @moduledoc """
  Runs a PerfLang test suite (C165), or a worker or a monitoring agent (C185) for one:

      mix aetherion run t6.perf --config staging.perfcfg --seed 42
      mix aetherion worker --name worker1@10.0.0.11
      mix aetherion agent --name sutServer1@10.0.0.21

  The process exits with 0 when every Test passed, 1 when a Test failed and 2
  when the run could not start or finish (C132). `bin/aetherion` runs the same
  command and also turns Ctrl+C into a clean stop (C155).
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    # bin/aetherion runs Mix from the project, so paths resolve from where it was called (C119).
    case System.get_env("AETHERION_CWD") do
      nil -> :ok
      directory -> File.cd!(directory)
    end

    System.halt(Aetherion.CLI.main(args))
  end
end
