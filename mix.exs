# emqtt pulls in a native QUIC library that PerfLang does not use (C163).
System.put_env("BUILD_WITHOUT_QUIC", "1")

defmodule Aetherion.MixProject do
  use Mix.Project

  def project do
    [
      app: :aetherion,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # src/perflang_lexer.xrl and src/perflang_parser.yrl are compiled by
      # Mix's built-in :leex and :yecc compilers.
      compilers: [:leex, :yecc] ++ Mix.compilers(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :ssl]]
  end

  defp deps do
    [
      {:mint, "~> 1.11"},
      {:castore, "~> 1.0"},
      {:emqtt, "~> 1.16"}
    ]
  end
end
