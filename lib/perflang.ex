defmodule PerfLang do
  @moduledoc """
  Front end for PerfLang, the performance-testing DSL.

      {:ok, ast} = PerfLang.parse(source)

      {:ok, ast} = PerfLang.validate(ast)

      {:ok, config} = PerfLang.parse_config_file("staging.perfcfg")
      {:ok, config} = PerfLang.validate(config)
      {:ok, ast} = PerfLang.analyze(ast, config: config)

  The pipeline is lexer (`PerfLang.Lexer`, leex), parser
  (`PerfLang.Parser`, yecc), `PerfLang.Validator`, then
  `PerfLang.Analyzer`. The lexer and parser return
  `{:error, %PerfLang.Error{}}` for the first problem; the Validator and the
  Analyzer return `{:error, [%PerfLang.Error{}]}` with every problem. All
  errors carry a line and column. The analyzed `PerfLang.AST`, with the type
  of every expression, is the input for the execution engine.
  """

  alias PerfLang.{Analyzer, Error, Lexer, Parser, Validator}

  defdelegate tokenize(source), to: Lexer
  defdelegate parse(source), to: Parser
  defdelegate parse_config(source), to: Parser
  defdelegate validate(ast), to: Validator
  defdelegate analyze(ast, opts \\ []), to: Analyzer

  @doc "Reads and parses a file. Errors carry the file name."
  def parse_file(path) do
    case Parser.parse(File.read!(path)) do
      {:ok, ast} -> {:ok, ast}
      {:error, %Error{} = e} -> {:error, %{e | file: path}}
    end
  end

  @doc "Reads and parses an external configuration file (C157). Errors carry the file name."
  def parse_config_file(path) do
    case Parser.parse_config(File.read!(path)) do
      {:ok, config} -> {:ok, config}
      {:error, %Error{} = e} -> {:error, %{e | file: path}}
    end
  end

  @doc "Like `parse/1`, but raises `PerfLang.Error`."
  def parse!(source) do
    case parse(source) do
      {:ok, ast} -> ast
      {:error, e} -> raise e
    end
  end
end
