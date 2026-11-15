defmodule Aetherion.Cluster do
  @moduledoc """
  The main server's side of a run on workers.

  The main server runs everything that happens once: the stages, Setup, Verify,
  Cleanup, stopIf, the monitoring of the system under test and the report. The
  workers only run virtual users through Actions. The nodes are connected by
  Erlang distribution, with long names and a shared cookie.

  For each Test the main server starts a session on every worker
  (`Aetherion.Worker`) and splits each user count across them, the first workers
  taking one more when it does not divide evenly. A worker sends the requests
  that count every 200ms, so stopIf and the metrics read here see every worker.
  When the stages end, each worker stops its users, waits for their requests, and
  sends the rest: its asserts, checks and failures, its request attempts for the
  requests file, the Actions variables Verify and Cleanup read (C136), and what
  its users added to the lists of Setup (C137).

  Not yet across workers: stages that count iterations (`iter`, `iter/vu`), which
  `check/1` rejects. An `add` from Actions reaches Verify and Cleanup, but not the
  users of other workers during the run. The Actions variable Verify reads comes
  from the worker that reported last. Each worker starts its warmup when it
  joins, so warmup ends a network delay later there. `loadGenerator` reads the
  main server, which sends no load.
  """

  alias PerfLang.AST
  alias Aetherion.Recorder

  # ---------- Connecting ----------

  @doc """
  Starts this node and connects to `workers`, a list of node names such as
  `"worker1@10.0.0.11"`. Options: `:name`, this node's name, by default
  `aetherion-<os pid>@<the address that reaches the first worker>`; `:cookie`, by
  default `$AETHERION_COOKIE`. Every worker must run the same code as this node.
  """
  def connect(workers, opts \\ []) do
    with {:ok, nodes} <- parse(workers),
         {:ok, cookie} <- cookie(opts[:cookie]),
         :ok <- start_self(opts[:name], hd(nodes), cookie) do
      Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, connected} ->
        case reach(node) do
          :ok -> {:cont, {:ok, connected ++ [node]}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
    end
  end

  defp parse(workers) do
    nodes = for name <- workers, name = String.trim(name), name != "", do: name

    cond do
      nodes == [] ->
        {:error, "--workers needs at least one worker, such as worker1@10.0.0.11"}

      bad = Enum.find(nodes, &(not String.match?(&1, ~r/^[^@\s]+@[^@\s]+$/))) ->
        {:error, "#{bad} is not a node name; write it as name@host, such as worker1@10.0.0.11"}

      length(Enum.uniq(nodes)) < length(nodes) ->
        {:error, "a worker is listed twice in --workers"}

      true ->
        {:ok, Enum.map(nodes, &String.to_atom/1)}
    end
  end

  @doc "The cookie from the option or `$AETHERION_COOKIE`."
  def cookie(nil) do
    case System.get_env("AETHERION_COOKIE") do
      value when value in [nil, ""] ->
        {:error, "workers need a shared cookie: set AETHERION_COOKIE, or pass --cookie"}

      value ->
        {:ok, value}
    end
  end

  def cookie(value), do: {:ok, value}

  defp start_self(name, first_worker, cookie) do
    with {:ok, name} <- own_name(name, first_worker),
         :ok <- start_node(name, hidden: true) do
      Node.set_cookie(String.to_atom(cookie))
      :ok
    end
  end

  defp own_name(nil, worker) do
    [_name, host] = worker |> Atom.to_string() |> String.split("@")

    case address_for(host) do
      {:ok, address} ->
        {:ok, "aetherion-#{System.pid()}@#{address}"}

      :error ->
        {:error, "cannot tell which address reaches #{host}; pass --name main@<this server's address>"}
    end
  end

  defp own_name(name, _worker), do: {:ok, name}

  # The local address the system would send from to reach host. A UDP socket only
  # picks the route when it connects, so no packet is sent.
  defp address_for(host) do
    {:ok, socket} = :gen_udp.open(0)

    try do
      with :ok <- :gen_udp.connect(socket, String.to_charlist(host), 9),
           {:ok, {address, _port}} <- :inet.sockname(socket) do
        {:ok, address |> :inet.ntoa() |> to_string()}
      else
        _ -> :error
      end
    after
      :gen_udp.close(socket)
    end
  end

  @doc """
  Makes this node a distributed node called `name`, with long names, starting epmd
  first as `erl -name` would. Nothing to do when the node is already distributed.

  The main server is a hidden node (`hidden: true`), so its workers do not connect
  to each other: they never need to, and `global` would otherwise disconnect
  nodes when one worker goes away.
  """
  def start_node(name, opts \\ []) do
    if Node.alive?() do
      :ok
    else
      start_epmd()
      options = %{name_domain: :longnames, hidden: Keyword.get(opts, :hidden, false)}

      case :net_kernel.start(String.to_atom(name), options) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, "cannot start the node #{name}: #{inspect(reason)}"}
      end
    end
  end

  defp start_epmd do
    erts = Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "bin", "epmd"])
    epmd = if File.exists?(erts), do: erts, else: System.find_executable("epmd")
    if epmd, do: System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)
    :ok
  end

  defp reach(node) do
    cond do
      not Node.connect(node) ->
        {:error,
         "cannot reach the worker #{node}: is `aetherion worker` running there, with the same cookie, " <>
           "and are ports 4369 and the distribution ports open?"}

      not worker?(node) ->
        {:error, "#{node} is not an Aetherion worker; start it with `aetherion worker --name #{node}`"}

      :erpc.call(node, __MODULE__, :fingerprint, []) != fingerprint() ->
        {:error, "the worker #{node} runs different code; deploy the same version on every server"}

      true ->
        :ok
    end
  end

  defp worker?(node) do
    :erpc.call(node, Aetherion.Worker, :ready?, [])
  rescue
    _error -> false
  end

  @doc "A hash of the code of the engine and the language, the same on every node that runs one version."
  def fingerprint do
    Application.load(:aetherion)
    {:ok, modules} = :application.get_key(:aetherion, :modules)

    modules
    |> Enum.sort()
    |> Enum.map(&{&1, &1.module_info(:md5)})
    |> :erlang.phash2()
  end

  # ---------- What runs on workers ----------

  @doc """
  The parts of a suite workers cannot run yet: stages that count iterations, and a
  Load without stages, which runs one iteration (C103).
  """
  def check(%AST.TestSuite{} = ast) do
    errors =
      for test <- ast.tests,
          load = test.load || ast.load,
          error <- load_errors(test, load),
          do: error

    if errors == [], do: :ok, else: {:error, Enum.uniq(errors)}
  end

  defp load_errors(%AST.Test{name: name, loc: loc}, nil),
    do: [error(loc, "Test #{name} has no Load; on workers every stage needs a time, such as 10vu for 5m")]

  defp load_errors(%AST.Test{name: name}, %AST.Load{settings: settings, loc: loc}) do
    case Enum.find(settings, &match?(%AST.Stages{}, &1)) do
      nil ->
        [error(loc, "Test #{name} has no stages; on workers every stage needs a time, such as 10vu for 5m")]

      %AST.Stages{stages: stages} ->
        for %{duration: %AST.IterationsLiteral{}, loc: loc} <- stages do
          error(
            loc,
            "stages that count iterations do not run on workers yet; give the stage a time, such as 5m"
          )
        end
    end
  end

  defp error({line, column}, message),
    do: %PerfLang.Error{stage: :workers, message: message, line: line, column: column}

  defp error(nil, message), do: error({1, 1}, message)

  # ---------- One Test ----------

  @doc "Starts a session on every worker, for the Actions of the Test in `ctx`."
  def start(workers, ctx) do
    test = ctx.test
    count = length(workers)

    job = %{
      ctx: %{ctx | test: %{test | recorder: nil, monitor: nil, cells: nil, vars: nil}},
      cells: :ets.tab2list(test.cells),
      cells_table: test.cells,
      requests?: ctx.rt.output.requests != nil,
      warmup_left_ms: Recorder.warmup_left(test.recorder),
      step: count
    }

    sessions =
      workers
      |> Enum.with_index(1)
      |> Enum.reduce([], fn {node, index}, started ->
        try do
          job = Map.put(job, :first, index)
          pid = :erpc.call(node, Aetherion.Worker, :start_session, [self(), job, Recorder.now()])
          started ++ [%{node: node, pid: pid, ref: Process.monitor(pid), users: 0}]
        catch
          kind, reason ->
            abort(%{sessions: started})
            raise "cannot start the users on the worker #{node}: #{Exception.format_banner(kind, reason)}"
        end
      end)

    %{sessions: sessions}
  end

  @doc "Splits `target` users across the workers, and tells each worker whose share changed."
  def resize(%{sessions: sessions} = cluster, target) do
    count = length(sessions)

    sessions =
      sessions
      |> Enum.with_index()
      |> Enum.map(fn {session, index} ->
        share = div(target, count) + if(index < rem(target, count), do: 1, else: 0)
        if share != session.users, do: send(session.pid, {:users, share})
        %{session | users: share}
      end)

    %{cluster | sessions: sessions}
  end

  @doc """
  Ends the Test on every worker and adds what each recorded to `test`, the main
  server's Test. A worker gets `grace_ms` for its users' last requests, and a
  little more to send what it recorded.
  """
  def stop(%{sessions: sessions} = cluster, test, grace_ms) do
    Enum.each(sessions, &send(&1.pid, :stop))
    await(cluster, sessions, test, Recorder.now() + grace_ms + 10_000)
  end

  defp await(_cluster, [], _test, _deadline), do: :ok

  defp await(cluster, waiting, test, deadline) do
    receive do
      {:aetherion_counted, rows} ->
        Recorder.merge_counted(test.recorder, rows)
        await(cluster, waiting, test, deadline)

      {:aetherion_done, pid, result} ->
        session = Enum.find(waiting, &(&1.pid == pid))
        Process.demonitor(session.ref, [:flush])
        merge(test, result)
        await(cluster, List.delete(waiting, session), test, deadline)

      {:DOWN, _ref, :process, pid, reason} ->
        lost!(cluster, pid, reason)

      :perflang_interrupt ->
        await(cluster, waiting, test, deadline)
    after
      max(trunc(deadline - Recorder.now()), 0) ->
        abort(cluster)
        raise "the worker #{hd(waiting).node} did not finish its users in time"
    end
  end

  defp merge(test, result) do
    Recorder.merge_counted(test.recorder, result.counted)
    Recorder.merge(test.recorder, result.recorder)
    :ets.insert(test.vars, result.vars)

    for {{id, _key}, value} <- result.cell_adds,
        do: :ets.insert(test.cells, {{id, :erlang.unique_integer([:monotonic])}, value})
  end

  @doc "Stops every session at once, without waiting for their users."
  def abort(%{sessions: sessions}) do
    Enum.each(sessions, fn session ->
      Process.demonitor(session.ref, [:flush])
      send(session.pid, :abort)
    end)
  end

  @doc "A session went down during the run: the other workers stop, and the run cannot finish (C132)."
  def lost!(cluster, pid, reason) do
    node = Enum.find_value(cluster.sessions, node(pid), &(&1.pid == pid && &1.node))
    abort(cluster)

    case reason do
      :noconnection ->
        raise "lost the connection to the worker #{node}"

      {%{__exception__: true} = error, _stack} ->
        raise "the worker #{node} failed: #{Exception.message(error)}"

      other ->
        raise "the worker #{node} failed: #{inspect(other)}"
    end
  end
end
