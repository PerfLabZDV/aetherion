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
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :ssl]]
  end

  defp deps do
    [
      # The language: lexer, parser, validator, analyzer and the typed AST.
      {:perflang, path: "../perflang"},
      {:mint, "~> 1.11"},
      {:castore, "~> 1.0"},
      {:emqtt, "~> 1.16"}
    ]
  end
end
