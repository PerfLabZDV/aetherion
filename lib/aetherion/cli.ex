defmodule Aetherion.CLI do
  @moduledoc """
  `aetherion run file.perf [--config staging.perfcfg] [--seed 42] [--runs 10]` (C165, C178).

  Returns the exit code of C132: 0 when every Test passed, 1 when a Test failed,
  2 when the run could not start or finish.
  """

  @usage "usage: mix aetherion run file.perf [--config file.perfcfg] [--seed n] [--runs n]"

  def main(["run" | args]) do
    case OptionParser.parse(args, strict: [config: :string, seed: :integer, runs: :integer]) do
      {options, [file], []} -> run(file, options)
      _ -> usage()
    end
  end

  def main(_args), do: usage()

  defp usage do
    IO.puts(:stderr, @usage)
    2
  end

  defp run(file, options) do
    with {:ok, ast} <- PerfLang.parse_file(file) |> one(),
         {:ok, ast} <- PerfLang.validate(ast),
         {:ok, config} <- config(options[:config]),
         {:ok, ast} <- PerfLang.analyze(ast, config: config),
         {:ok, _plan} <- plan(ast, options[:runs]) do
      {:ok, _started} = Application.ensure_all_started(:ssl)
      Aetherion.run(ast, seed: options[:seed], runs: options[:runs]).exit_code
    else
      {:error, :runs, message} ->
        IO.puts(:stderr, "--runs: #{message}")
        2

      {:error, errors} ->
        Enum.each(errors, &IO.puts(:stderr, PerfLang.Error.format(&1)))
        2
    end
  rescue
    error in File.Error ->
      IO.puts(:stderr, Exception.message(error))
      2
  end

  # --runs replaces the count of the runs section, and must leave a counted run (C178).
  defp plan(ast, runs) do
    case Aetherion.plan(ast, runs) do
      {:ok, plan} -> {:ok, plan}
      {:error, message} -> {:error, :runs, message}
    end
  end

  defp one({:error, %PerfLang.Error{} = error}), do: {:error, [error]}
  defp one(result), do: result

  defp config(nil), do: {:ok, nil}

  defp config(path) do
    with {:ok, config} <- path |> PerfLang.parse_config_file() |> one() do
      PerfLang.validate(config)
    end
  end
end
