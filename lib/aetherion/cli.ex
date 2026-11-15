defmodule Aetherion.CLI do
  @moduledoc """
  `aetherion run file.perf [--config staging.perfcfg] [--seed 42] [--runs 10]` (C165, C178).

  Returns the exit code of C132: 0 when every Test passed, 1 when a Test failed,
  2 when the run could not start or finish.

  The virtual users run on the workers of the Config, `workers { w1 { host =
  "10.0.0.11"; } }` (C181), each started with `aetherion worker --name
  w1@10.0.0.11`, which waits for runs. `--workers w1@10.0.0.11,w2@10.0.0.12`
  replaces that section (C184). Main server and workers share a cookie, from
  `$AETHERION_COOKIE` or `--cookie`, and `--name` names the main server's node
  (`Aetherion.Cluster`).
  """

  alias Aetherion.{Cluster, Worker}

  @usage """
  usage: aetherion run file.perf [--config file.perfcfg] [--seed n] [--runs n]
                                 [--workers name@host,...] [--cookie c] [--name name@host]
         aetherion worker --name name@host [--cookie c]\
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
        run(file, options)

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
         {:ok, config} <- command_line_workers(config, options[:workers]),
         {:ok, ast} <- PerfLang.analyze(ast, config: config),
         {:ok, _plan} <- plan(ast, options[:runs]),
         {:ok, workers} <- workers(ast, options) do
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

  # --workers replaces the workers section (C184): each node name, name@host, is a
  # worker, written as one so the Validator checks it like any other.
  defp command_line_workers(config, nil), do: {:ok, config}

  defp command_line_workers(config, list) do
    nodes = for node <- String.split(list, ","), node = String.trim(node), node != "", do: node

    case Enum.find(nodes, &(not String.match?(&1, ~r/^[A-Za-z][A-Za-z0-9_]*@[^@\s"]+$/))) do
      nil when nodes != [] ->
        entries = Enum.map_join(nodes, " ", &worker_entry/1)
        {:ok, section} = PerfLang.parse_config("Config { workers { #{entries} } }")

        case PerfLang.validate(section) do
          {:ok, section} -> {:ok, with_workers(config, section)}
          {:error, errors} -> {:error, :workers, "--workers: " <> Enum.map_join(errors, "; ", & &1.message)}
        end

      nil ->
        {:error, :workers, "--workers needs at least one worker, such as euWorker1@10.0.0.11 (C184)"}

      bad ->
        {:error, :workers,
         "--workers: #{bad} is not name@host with a name such as euWorker1, letters, digits and _ (C184)"}
    end
  end

  defp worker_entry(node) do
    [name, host] = String.split(node, "@")
    ~s|#{name} { host = "#{host}"; }|
  end

  defp with_workers(nil, section), do: section

  defp with_workers(%PerfLang.AST.Config{sections: sections} = config, %PerfLang.AST.Config{
         sections: [workers]
       }),
       do: %{config | sections: Enum.reject(sections, &match?(%PerfLang.AST.Workers{}, &1)) ++ [workers]}

  # The workers of the merged Config (C181), connected before any Test starts (C184).
  defp workers(ast, options) do
    case Aetherion.workers(ast) do
      [] ->
        if options[:cookie] || options[:name],
          do:
            {:error, :workers, "--cookie and --name are for runs on workers; the suite has no workers (C181)"},
          else: {:ok, []}

      nodes ->
        case Cluster.connect(nodes, name: options[:name], cookie: options[:cookie]) do
          {:ok, nodes} -> {:ok, nodes}
          {:error, message} -> {:error, :workers, message}
        end
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
