Code.require_file("server_helper.exs", __DIR__)

defmodule Aetherion.ClusterTest do
  # Workers are real nodes on this machine, started with :peer, running the code of this test run.
  use ExUnit.Case, async: false

  alias Aetherion.{Cluster, TestServer}

  @cookie "aetherion-test"

  setup_all do
    :ok = Cluster.start_node("aetherion-test-#{System.pid()}@127.0.0.1", hidden: true)
    Node.set_cookie(String.to_atom(@cookie))
    :ok
  end

  defp worker(opts \\ []) do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, node} =
      :peer.start(%{
        name: :"worker#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", String.to_charlist(@cookie) | paths]
      })

    if Keyword.get(opts, :ready, true), do: :ok = :erpc.call(node, Aetherion.Worker, :prepare, [])

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _kind, _reason -> :ok
      end
    end)

    {peer, node}
  end

  defp workers(count) do
    pairs = for _n <- 1..count, do: worker()

    {:ok, nodes} =
      Cluster.connect(Enum.map(pairs, fn {_peer, node} -> Atom.to_string(node) end), cookie: @cookie)

    {Enum.map(pairs, &elem(&1, 0)), nodes}
  end

  defp server(routes) do
    server = TestServer.start(routes)
    on_exit(fn -> TestServer.stop(server) end)
    server
  end

  defp suite(server, parts) do
    """
    TestSuite S {
      Config { sut { api { baseUrl = "#{server.url}"; } } #{parts[:output]} }
      Test T {
        Load { #{parts[:load]} }
        #{if parts[:setup], do: "Setup { #{parts[:setup]} }"}
        Actions { #{parts[:actions]} }
        #{if parts[:verify], do: "Verify { #{parts[:verify]} }"}
        #{if parts[:cleanup], do: "Cleanup { #{parts[:cleanup]} }"}
      }
    }
    """
  end

  defp analyze(source) do
    {:ok, ast} = source |> PerfLang.parse!() |> PerfLang.validate()
    {:ok, ast} = PerfLang.analyze(ast)
    ast
  end

  defp run(source, opts),
    do: Aetherion.run(analyze(source), Keyword.merge([report: false, signals: false], opts))

  defp totals(run), do: hd(hd(run.runs).tests).snapshot.totals

  defp ms(time),
    do: time |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix(:microsecond) |> Kernel./(1000)

  defp temp(name),
    do:
      Path.join(System.tmp_dir!(), "aetherion-#{System.pid()}-#{System.unique_integer([:positive])}-#{name}")

  # Requests still arriving a while after the run would mean users outlived it.
  defp settled?(server) do
    before = length(TestServer.requests(server))
    Process.sleep(300)
    length(TestServer.requests(server)) == before
  end

  describe "a run on workers" do
    test "the workers run the users, and the main server counts every request" do
      server = server(fn _ -> {:sleep, 5, 200} end)
      file = temp("requests.jsonl")
      {_peers, nodes} = workers(2)

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; fields = [virtualUser, status]; } }|,
          load: "stages [ 2vu now, 5vu in 300ms, 5vu for 700ms ]",
          actions: ~S"""
          let response = sut.api.http.get("/products");
          assert response.status == 200;
          """,
          verify: "assert errors.rate() < 1%; assert latency.p95() < 1s;"
        )

      result = run(source, workers: nodes)

      assert result.exit_code == 0
      assert settled?(server)
      sent = length(TestServer.requests(server))
      assert sent > 20
      assert totals(result).requests == sent

      lines = file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      assert length(lines) == sent
      # Numbered across the workers: worker 1 has users 1, 3, 5 and worker 2 has 2 and 4.
      assert lines |> Enum.map(& &1["virtualUser"]) |> Enum.uniq() |> Enum.sort() == [1, 2, 3, 4, 5]
      assert hd(hd(result.runs).tests).snapshot.totals.latency.p95 != nil
    end

    test "stopIf sees the requests of every worker" do
      server = server(fn _ -> 500 end)
      {_peers, nodes} = workers(2)

      source =
        suite(server,
          load: "stopIf errors.rate() > 50%; stages [ 4vu for 30s ]",
          actions: ~S|sut.api.http.get("/");|
        )

      started = System.monotonic_time(:millisecond)
      result = run(source, workers: nodes)

      assert System.monotonic_time(:millisecond) - started < 10_000
      assert hd(hd(result.runs).tests).stopped_by == "errors.rate() > 50%"
      assert settled?(server)
    end

    test "Verify reads the Actions variables and the list adds of the workers (C136, C137)" do
      server = server(fn _ -> 200 end)
      {_peers, nodes} = workers(2)

      source =
        suite(server,
          load: "stages [ 4vu for 500ms ]",
          setup: "let base = 40; let mut statuses = [];",
          actions: ~S"""
          let response = sut.api.http.get("/");
          statuses.add(response.status);
          let answer = base + 2;
          """,
          verify: "assert answer == 42; assert statuses.length() > 0;",
          cleanup: ~S|sut.api.http.get("/cleanup?n=" + statuses.length().toString());|
        )

      result = run(source, workers: nodes)

      assert result.exit_code == 0
      sent = Enum.count(TestServer.requests(server), &(&1.path == "/"))
      assert sent > 0
      assert Enum.any?(TestServer.requests(server), &(&1.target == "/cleanup?n=#{sent}"))
    end

    test "an interrupt stops the users on the workers, and Cleanup still runs (C155)" do
      server = server(fn _ -> {:sleep, 5, 200} end)
      {_peers, nodes} = workers(2)

      source =
        suite(server,
          load: "stages [ 4vu for 30s ]",
          actions: ~S|sut.api.http.get("/");|,
          verify: ~S|sut.api.http.get("/verify");|,
          cleanup: ~S|sut.api.http.get("/cleanup");|
        )

      Process.send_after(self(), :perflang_interrupt, 600)
      result = run(source, workers: nodes)

      assert result.exit_code == 2
      assert settled?(server)
      paths = Enum.map(TestServer.requests(server), & &1.path)
      assert "/cleanup" in paths
      refute "/verify" in paths
      assert totals(result).requests == Enum.count(paths, &(&1 == "/"))
    end

    test "a worker that goes away ends the run with exit code 2, and the other stops its users" do
      server = server(fn _ -> {:sleep, 5, 200} end)
      {[first, _second], nodes} = workers(2)

      source =
        suite(server,
          load: "stages [ 4vu for 30s ]",
          actions: ~S|sut.api.http.get("/");|,
          cleanup: ~S|sut.api.http.get("/cleanup");|
        )

      spawn(fn ->
        Process.sleep(500)
        :peer.stop(first)
      end)

      started = System.monotonic_time(:millisecond)

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          result = run(source, workers: nodes)
          assert result.exit_code == 2
        end)

      assert System.monotonic_time(:millisecond) - started < 10_000
      assert output =~ "worker"
      assert settled?(server)
      assert "/cleanup" in Enum.map(TestServer.requests(server), & &1.path)
    end
  end

  describe "stages with a count on workers (C103, C175)" do
    defp lines(file), do: file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    test "a total is split across the workers and runs exactly" do
      server = server(fn _ -> {:sleep, 2, 200} end)
      file = temp("total.jsonl")
      {_peers, nodes} = workers(2)

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; fields = [virtualUser]; } }|,
          load: "stages [ 5vu for 41iter ]",
          actions: ~S|sut.api.http.get("/");|
        )

      result = run(source, workers: nodes)

      assert result.exit_code == 0
      assert settled?(server)
      assert length(TestServer.requests(server)) == 41
      assert totals(result).requests == 41
      assert file |> lines() |> Enum.map(& &1["virtualUser"]) |> Enum.uniq() |> Enum.sort() == [1, 2, 3, 4, 5]
    end

    test "iter/vu gives every user its own count, on its worker" do
      server = server(fn _ -> 200 end)
      file = temp("per-user.jsonl")
      {_peers, nodes} = workers(2)

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; fields = [virtualUser, iteration]; } }|,
          load: "stages [ 5vu for 3iter/vu ]",
          actions: ~S|sut.api.http.get("/");|
        )

      assert run(source, workers: nodes).exit_code == 0
      assert file |> lines() |> Enum.frequencies_by(& &1["virtualUser"]) == Map.new(1..5, &{&1, 3})
    end

    test "a ramp by iterations finishes when its users reach some workers late" do
      # From 0 to 3 users on 3 workers: each worker has a part, but the ramp has one
      # user while the first part is used up, so the users must move to the others.
      server = server(fn _ -> {:sleep, 2, 200} end)
      {_peers, nodes} = workers(3)

      source = suite(server, load: "stages [ 3vu in 30iter ]", actions: ~S|sut.api.http.get("/");|)
      result = run(source, workers: nodes)

      assert result.exit_code == 0
      assert length(TestServer.requests(server)) == 30
    end

    test "a Load without stages runs one iteration, and a time stage can follow a count" do
      server = server(fn _ -> 200 end)
      {_peers, nodes} = workers(2)

      result =
        run(suite(server, load: "requestTimeout 5s;", actions: ~S|sut.api.http.get("/");|), workers: nodes)

      assert result.exit_code == 0
      assert length(TestServer.requests(server)) == 1

      source =
        suite(server,
          load: "stages [ 2vu for 10iter, 2vu for 300ms ]",
          actions: ~S|sut.api.http.get("/next");|
        )

      assert run(source, workers: nodes).exit_code == 0
      assert Enum.count(TestServer.requests(server), &(&1.path == "/next")) > 10
    end
  end

  describe "one clock across workers" do
    test "the workers send their request attempts during the run, and the main server writes them" do
      server = server(fn _ -> {:sleep, 2, 200} end)
      file = temp("streamed.jsonl")
      {_peers, nodes} = workers(2)

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; fields = [virtualUser]; } }|,
          load: "requestTimeout 200ms; stages [ 4vu for 4s ]",
          actions: ~S|sut.api.http.get("/");|
        )

      task = Task.async(fn -> run(source, workers: nodes) end)
      Process.sleep(3200)
      assert Task.yield(task, 0) == nil
      assert file |> File.read!() |> String.split("\n", trim: true) |> length() > 0

      assert %{exit_code: 0} = Task.await(task, 15_000)
      assert settled?(server)
      users = file |> lines() |> Enum.map(& &1["virtualUser"])
      assert length(users) == length(TestServer.requests(server))
      assert users |> Enum.uniq() |> Enum.sort() == [1, 2, 3, 4]
    end

    test "the requests file is in time order across workers, and warmup ends at once on all of them" do
      server = server(fn _ -> {:sleep, 2, 200} end)
      file = temp("clock.jsonl")
      {_peers, nodes} = workers(2)

      source =
        suite(server,
          output:
            ~s|output { requests { file = "#{file}"; fields = [time, virtualUser]; includeWarmup = true; } }|,
          load: "warmup 300ms; stages [ 4vu for 700ms ]",
          actions: ~S|sut.api.http.get("/");|
        )

      assert run(source, workers: nodes).exit_code == 0
      records = Enum.map(lines(file), &Map.put(&1, "ms", ms(&1["time"])))

      # Each worker's VM has a monotonic clock of its own; the file is sorted on the main server's.
      for [earlier, later] <- Enum.chunk_every(records, 2, 1, :discard),
          do: assert(later["ms"] >= earlier["ms"] - 5)

      {warm, measured} = Enum.split_with(records, & &1["warmup"])
      users = fn list -> list |> Enum.map(& &1["virtualUser"]) |> Enum.uniq() |> Enum.sort() end
      assert users.(warm) == [1, 2, 3, 4]
      assert users.(measured) == [1, 2, 3, 4]
      assert Enum.max_by(warm, & &1["ms"])["ms"] <= Enum.min_by(measured, & &1["ms"])["ms"] + 5
    end

    test "Verify reads the Actions variable of the last iteration, whichever worker ran it (C136)" do
      counter = :counters.new(1, [])

      server =
        server(fn
          %{path: "/next"} ->
            :counters.add(counter, 1, 1)
            {200, %{"n" => :counters.get(counter, 1)}}

          _other ->
            200
        end)

      {_peers, nodes} = workers(2)

      # The last 400ms only the first worker has a user, so its last value is the latest.
      source =
        suite(server,
          load: "stages [ 2vu now, 2vu for 400ms, 1vu for 400ms ]",
          actions: ~S"""
          let response = sut.api.http.get("/next");
          let n = response.body["n"];
          """,
          cleanup: ~S|sut.api.http.get("/last?n=" + n.toString());|
        )

      assert run(source, workers: nodes).exit_code == 0
      assert Enum.any?(TestServer.requests(server), &(&1.target == "/last?n=#{:counters.get(counter, 1)}"))
    end
  end

  describe "load generators on workers (C181, C183, C184)" do
    defp name_of(node), do: node |> Atom.to_string() |> String.split("@") |> hd()

    defp workers_section(nodes),
      do: "workers { " <> Enum.map_join(nodes, " ", &~s|#{name_of(&1)} { host = "127.0.0.1"; }|) <> " }"

    test "the workers are the load generators, all together and each one" do
      server = server(fn _ -> {:sleep, 2, 200} end)
      samples = temp("samples.jsonl")
      {_peers, [first, second] = nodes} = workers(2)

      source =
        suite(server,
          output:
            ~s|output { samples { file = "#{samples}"; } } monitoring { interval = 200ms; } #{workers_section(nodes)}|,
          load: "stages [ 2vu for 1500ms ]",
          actions: ~S|sut.api.http.get("/");|,
          verify: """
          assert loadGenerator.cpu.max() <= 100%;
          assert loadGenerator.#{name_of(first)}.mem.max() > 0%;
          assert loadGenerator.#{name_of(second)}.cpu.mean() >= 0%;
          """
        )

      result = run(source, workers: nodes)
      assert result.exit_code == 0

      test = hd(hd(result.runs).tests)
      assert Enum.map(test.workers, & &1.name) == Enum.sort([name_of(first), name_of(second)])
      assert Enum.all?(test.workers, &(&1.readings["cpu"].samples > 0 and &1.readings["mem"].samples > 0))

      each = test.workers |> Enum.map(& &1.readings["mem"].samples) |> Enum.sum()
      assert test.load_generator["mem"].samples == each

      # The main server sends no load, so it is not sampled (C183).
      targets =
        samples |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!(&1)["target"])

      assert targets |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(Enum.map(nodes, &"loadGenerator.#{name_of(&1)}"))
    end

    test "a worker without a sample in the window fails the assert with no value (C164)" do
      server = server(fn _ -> 200 end)
      {_peers, nodes} = workers(2)

      # cpu needs two readings an interval apart, and the stage ends first.
      source =
        suite(server,
          output: "monitoring { interval = 10s; } #{workers_section(nodes)}",
          load: "stages [ 2vu for 300ms ]",
          actions: ~S|sut.api.http.get("/");|,
          verify: "assert loadGenerator.cpu.max() < 100%;"
        )

      result = run(source, workers: nodes)
      assert result.exit_code == 1
      assert [%{passed: false}] = hd(hd(result.runs).tests).verify
    end

    test "the command line connects to the workers of the Config, and --workers replaces them (C184)" do
      server = server(fn _ -> 200 end)
      {_peers, [node]} = workers(1)
      System.put_env("AETHERION_COOKIE", @cookie)
      on_exit(fn -> System.delete_env("AETHERION_COOKIE") end)

      reading = "assert loadGenerator.#{name_of(node)}.mem.max() > 0%;"
      body = [load: "stages [ 1vu for 400ms ]", actions: ~S|sut.api.http.get("/");|, verify: reading]

      with_section = temp("with.perf")
      File.write!(with_section, suite(server, [output: workers_section([node])] ++ body))
      without = temp("without.perf")
      File.write!(without, suite(server, body))

      cli = fn args ->
        ExUnit.CaptureIO.capture_io(fn -> send(self(), {:exit, Aetherion.CLI.main(args)}) end)
      end

      cli.(["run", with_section])
      assert_received {:exit, 0}

      cli.(["run", without, "--workers", Atom.to_string(node)])
      assert_received {:exit, 0}

      # Without workers the reading has no worker to read.
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          send(self(), {:exit, Aetherion.CLI.main(["run", without])})
        end)

      assert_received {:exit, 2}
      assert output =~ "unknown worker #{name_of(node)}"

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          send(self(), {:exit, Aetherion.CLI.main(["run", without, "--workers", "eu-worker@10.0.0.11"])})
        end)

      assert_received {:exit, 2}
      assert output =~ "eu-worker@10.0.0.11 is not name@host"
    end
  end

  describe "monitoring agents (C185)" do
    # An agent named like a target, so the target's node is name@127.0.0.1.
    defp agent(name \\ nil) do
      paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

      {:ok, peer, node} =
        :peer.start(%{
          name: name || :"agent#{System.unique_integer([:positive])}",
          host: ~c"127.0.0.1",
          longnames: true,
          args: [~c"-setcookie", String.to_charlist(@cookie) | paths]
        })

      :ok = :erpc.call(node, Aetherion.Agent, :prepare, [])

      on_exit(fn ->
        try do
          :peer.stop(peer)
        catch
          _kind, _reason -> :ok
        end
      end)

      {peer, node}
    end

    defp measured(server, name, parts) do
      """
      TestSuite S {
        Config {
          sut {
            api { baseUrl = "#{server.url}"; }
            #{name} { host = "127.0.0.1"; metrics = [#{parts[:metrics] || ~s|cpu, mem, disk, net["lo"]|}]; }
          }
          monitoring { interval = 50ms; format = aetherion; }
          #{parts[:output]}
        }
        Test T {
          Load { #{parts[:load] || "thinkTime 20ms; stages [ 1vu for 800ms ]"} }
          Actions { sut.api.http.get("/"); }
          Verify { #{parts[:verify]} }
        }
      }
      """
    end

    defp sample_lines(file),
      do: file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    test "an agent measures its machine, and its samples are on the main server's clock" do
      server = server(fn _ -> 200 end)
      samples = temp("agent_samples.jsonl")
      {_peer, node} = agent()
      name = name_of(node)

      # Each VM has its own monotonic clock, so without the offset no sample would fall in the window.
      source =
        measured(server, name,
          output: ~s|output { samples { file = "#{samples}"; } }|,
          verify: """
          assert sut.#{name}.cpu.max() <= 100%;
          assert sut.#{name}.mem.max() > 0%;
          assert sut.#{name}.net.mean() >= 0B/s;
          assert sut.mem.mean() > 0%;
          """
        )

      result = run(source, [])
      test = hd(hd(result.runs).tests)
      assert result.exit_code == 0, inspect(test.verify)

      assert [%{name: ^name, readings: readings}] = test.targets
      assert readings["mem"].samples >= 8
      assert readings["cpu"].samples >= 8

      lines = Enum.filter(sample_lines(samples), &(&1["target"] == name))
      assert lines |> Enum.map(& &1["metric"]) |> Enum.uniq() |> Enum.sort() == ["cpu", "disk", "mem", "net"]
      assert "Actions" in Enum.map(lines, & &1["phase"])
    end

    test "an agent that cannot be reached, or a node that is no agent, ends the run with exit code 2" do
      server = server(fn _ -> 200 end)

      result = run(measured(server, "nobody", metrics: "mem"), [])
      assert result.exit_code == 2
      assert hd(result.runs).message =~ "cannot reach the agent nobody@127.0.0.1"

      {_peer, node} = worker()
      result = run(measured(server, name_of(node), metrics: "mem"), [])
      assert result.exit_code == 2
      assert hd(result.runs).message =~ "is not an Aetherion agent"
    end

    test "a lost agent is reached again, and its samples go on" do
      server = server(fn _ -> 200 end)
      samples = temp("lost_samples.jsonl")
      name = :"agent#{System.unique_integer([:positive])}"
      {peer, _node} = agent(name)

      source =
        measured(server, name,
          metrics: "mem",
          output: ~s|output { samples { file = "#{samples}"; } }|,
          load: "thinkTime 20ms; stages [ 1vu for 3s ]",
          verify: "assert sut.#{name}.mem.max() > 0%;"
        )

      task = Task.async(fn -> run(source, []) end)
      Process.sleep(800)
      :peer.stop(peer)
      stopped = DateTime.utc_now()
      Process.sleep(500)
      agent(name)
      restarted = DateTime.utc_now()

      result = Task.await(task, 20_000)
      assert result.exit_code == 0

      times =
        for line <- sample_lines(samples), line["target"] == Atom.to_string(name) do
          {:ok, time, 0} = DateTime.from_iso8601(line["time"])
          time
        end

      assert Enum.any?(times, &(DateTime.compare(&1, stopped) == :lt))
      assert Enum.any?(times, &(DateTime.compare(&1, restarted) == :gt))

      refute Enum.any?(
               times,
               &(DateTime.compare(&1, stopped) == :gt and DateTime.compare(&1, restarted) == :lt)
             )
    end

    test "the command line connects to the agents before the run, and explains one it cannot reach" do
      server = server(fn _ -> 200 end)
      {_peer, node} = agent()
      name = name_of(node)
      System.put_env("AETHERION_COOKIE", @cookie)
      on_exit(fn -> System.delete_env("AETHERION_COOKIE") end)

      body = [metrics: "mem", load: "stages [ 1vu for 300ms ]"]
      reachable = temp("agent.perf")
      File.write!(reachable, measured(server, name, body ++ [verify: "assert sut.#{name}.mem.max() > 0%;"]))
      unreachable = temp("no_agent.perf")
      File.write!(unreachable, measured(server, "nobody", body))

      ExUnit.CaptureIO.capture_io(fn -> send(self(), {:exit, Aetherion.CLI.main(["run", reachable])}) end)
      assert_received {:exit, 0}

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          send(self(), {:exit, Aetherion.CLI.main(["run", unreachable])})
        end)

      assert_received {:exit, 2}
      assert output =~ "cannot reach the agent nobody@127.0.0.1: is `aetherion agent` running there"

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn -> send(self(), {:exit, Aetherion.CLI.main(["agent"])}) end)

      assert_received {:exit, 2}
      assert output =~ "aetherion agent --name name@host"
    end
  end

  describe "connect/2" do
    test "connects to agents, and explains a node that is no agent (C185)" do
      {_peer, node} = agent()
      assert {:ok, []} = Cluster.connect([], agents: [Atom.to_string(node)], cookie: @cookie)

      {_peer, worker} = worker()
      assert {:error, message} = Cluster.connect([], agents: [Atom.to_string(worker)], cookie: @cookie)
      assert message =~ "is not an Aetherion agent; start it with `aetherion agent --name #{worker}`"

      assert {:error, message} =
               Cluster.connect([Atom.to_string(worker)], agents: [Atom.to_string(worker)], cookie: @cookie)

      assert message =~ "listed twice"
    end

    test "explains a worker it cannot reach, a node that is no worker, and a bad name" do
      assert {:error, message} = Cluster.connect(["nobody@127.0.0.1"], cookie: @cookie)
      assert message =~ "cannot reach the worker nobody@127.0.0.1"

      {_peer, node} = worker(ready: false)
      assert {:error, message} = Cluster.connect([Atom.to_string(node)], cookie: @cookie)
      assert message =~ "is not an Aetherion worker"

      assert {:error, message} = Cluster.connect(["no-host"], cookie: @cookie)
      assert message =~ "name@host"
    end

    test "needs a cookie" do
      previous = System.get_env("AETHERION_COOKIE")
      System.delete_env("AETHERION_COOKIE")
      on_exit(fn -> if previous, do: System.put_env("AETHERION_COOKIE", previous) end)

      assert {:error, message} = Cluster.connect(["w@127.0.0.1"])
      assert message =~ "AETHERION_COOKIE"
    end
  end
end
