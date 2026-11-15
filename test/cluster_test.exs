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

  describe "check/1" do
    test "rejects stages that count iterations, and a Load without stages" do
      server = server(fn _ -> 200 end)

      assert {:error, [error]} =
               Cluster.check(analyze(suite(server, load: "stages [ 2vu for 10iter ]", actions: "")))

      assert error.message =~ "count iterations"
      assert error.line > 0

      assert {:error, [error]} =
               Cluster.check(analyze(suite(server, load: "requestTimeout 5s;", actions: "")))

      assert error.message =~ "no stages"

      assert :ok =
               Cluster.check(analyze(suite(server, load: "stages [ 2vu in 1s, 2vu for 1m ]", actions: "")))
    end

    test "Aetherion.run refuses them too" do
      server = server(fn _ -> 200 end)

      assert_raise ArgumentError, ~r/count iterations/, fn ->
        run(suite(server, load: "stages [ 2vu for 1iter/vu ]", actions: ""), workers: [node()])
      end
    end
  end

  describe "connect/2" do
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
