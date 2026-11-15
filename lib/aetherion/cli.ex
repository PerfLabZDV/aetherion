defmodule Aetherion.CLI do
  @moduledoc """
  `aetherion run file.perf [--config staging.perfcfg] [--seed 42] [--runs 10]` (C165, C178).

  Returns the exit code of C132: 0 when every Test passed, 1 when a Test failed,
  2 when the run could not start or finish.

  `--workers w1@10.0.0.11,w2@10.0.0.12` runs the virtual users on workers, each
  started with `aetherion worker --name w1@10.0.0.11`, which waits for runs. Main
  server and workers share a cookie, from `$AETHERION_COOKIE` or `--cookie`, and
  `--name` names the main server's node (`Aetherion.Cluster`).
  """

  alias Aetherion.{Cluster, Worker}

  @usage """
  usage: mix aetherion run file.perf [--config file.perfcfg] [--seed n] [--runs n]
                                     [--workers name@host,... [--cookie c] [--name name@host]]
         mix aetherion worker --name name@host [--cookie c]\
  """

  @run_options [
    config: :string,
    seed: :integer,
    runs: :integer,
    workers: :string,
    cookie: :string,
    name: :string
  ]

  def main(["run" | args]) do
    case OptionParser.parse(args, strict: @run_options) do
      {options, [file], []} ->
        if options[:workers] || not (Keyword.has_key?(options, :cookie) or Keyword.has_key?(options, :name)),
          do: run(file, options),
          else: usage()

      _ ->
        usage()
    end
  end

  def main(["worker" | args]) do
    with {options, [], []} <- OptionParser.parse(args, strict: [name: :string, cookie: :string]),
         name when is_binary(name) <- options[:name] do
      case Cluster.cookie(options[:cookie]) do
        {:ok, cookie} -> report(Worker.serve(name, cookie))
        error -> report(error)
      end
    else
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
         {:ok, _plan} <- plan(ast, options[:runs]),
         {:ok, workers} <- workers(ast, file, options) do
      {:ok, _started} = Application.ensure_all_started(:ssl)
      Aetherion.run(ast, seed: options[:seed], runs: options[:runs], workers: workers).exit_code
    else
      {:error, :runs, message} ->
        IO.puts(:stderr, "--runs: #{message}")
        2

      {:error, :workers, message} ->
        report({:error, message})

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

  # The suite must suit workers before any is reached.
  defp workers(ast, file, options) do
    case options[:workers] do
      nil ->
        {:ok, []}

      list ->
        with :ok <- check(ast, file) do
          case Cluster.connect(String.split(list, ","), name: options[:name], cookie: options[:cookie]) do
            {:ok, nodes} -> {:ok, nodes}
            {:error, message} -> {:error, :workers, message}
          end
        end
    end
  end

  defp check(ast, file) do
    case Cluster.check(ast) do
      :ok -> :ok
      {:error, errors} -> {:error, Enum.map(errors, &%{&1 | file: file})}
    end
  end

  defp report({:error, message}) do
    IO.puts(:stderr, "error: #{message}")
    2
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
