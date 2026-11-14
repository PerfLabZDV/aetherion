defmodule PerfLang.MixProject do
  use Mix.Project

  def project do
    [
      app: :perflang,
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
    [extra_applications: [:logger]]
  end

  defp deps do
    []
  end
end
