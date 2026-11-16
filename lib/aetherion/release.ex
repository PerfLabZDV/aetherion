defmodule Aetherion.Release do
  @moduledoc """
  The command line of the release: `aetherion run ...`, `aetherion worker ...` and
  `aetherion agent ...`, the same as `mix aetherion` (`Aetherion.CLI`), for servers
  without Elixir.

  The `aetherion` command of the Debian package (packaging/debian) runs
  `/opt/aetherion/bin/aetherion eval "Aetherion.Release.main()" -- args`. eval starts
  no application, so the command line starts the ones it needs, as `mix aetherion`
  does, and paths stay relative to where it was called (C119).
  """

  def main(args \\ System.argv()) do
    {:ok, _started} = Application.ensure_all_started(:logger)
    Application.load(:aetherion)
    System.halt(Aetherion.CLI.main(args))
  end
end
