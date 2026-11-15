Code.require_file("server_helper.exs", __DIR__)

defmodule AetherionTest do
  use ExUnit.Case, async: false

  alias Aetherion.{TestBroker, TestServer}

  defp run(source, opts \\ []) do
    {config, opts} = Keyword.pop(opts, :config)
    {:ok, ast} = source |> PerfLang.parse!() |> PerfLang.validate()

    config =
      if config do
        {:ok, parsed} = PerfLang.parse_config(config)
        {:ok, parsed} = PerfLang.validate(parsed)
        parsed
      end

    {:ok, ast} = PerfLang.analyze(ast, config: config)
    Aetherion.run(ast, Keyword.merge([report: false, signals: false], opts))
  end

  defp server(routes) do
    server = TestServer.start(routes)
    on_exit(fn -> TestServer.stop(server) end)
    server
  end

  defp config(server, extra \\ "") do
    ~s|Config { sut { api { baseUrl = "#{server.url}"; } } #{extra} }|
  end

  defp suite(server, parts) do
    """
    TestSuite S {
      #{config(server, parts[:output] || "")}
      Test T {
        Load { #{parts[:load]} }
        Setup { #{parts[:setup]} }
        Actions { #{parts[:actions]} }
        Verify { #{parts[:verify]} }
        Cleanup { #{parts[:cleanup]} }
      }
    }
    """
    |> String.replace("Setup {  }", "")
    |> String.replace("Verify {  }", "")
    |> String.replace("Cleanup {  }", "")
  end

  # The Tests of the first run, with their snapshots (C178).
  defp tests(run), do: hd(run.runs).tests
  defp totals(run), do: hd(tests(run)).snapshot.totals
  # The OS pid keeps names apart across test runs: unique_integer restarts with every VM, and a file
  # left by an earlier run would make the engine write a timestamped file next to it (C119).
  defp temp(name),
    do: Path.join(System.tmp_dir!(), "perflang-#{System.pid()}-#{System.unique_integer([:positive])}-#{name}")

  describe "a journey" do
    test "requests go out with bodies, values flow between steps, and the Test passes" do
      server =
        server(fn
          %{method: "GET", path: "/api/products"} -> {200, %{"products" => [%{"id" => 7}, %{"id" => 8}]}}
          %{method: "POST", path: "/api/carts"} -> {201, %{"cartId" => "c-1"}}
          %{method: "POST", path: "/api/orders"} -> 201
        end)

      source =
        suite(server,
          load: "requestTimeout 5s; stages [ 3vu for 12iter ]",
          actions: ~S"""
          let catalog = sut.api.http.get("/api/products");
          assert catalog.status == 200;
          let productCatalog = catalog.body["products"];
          let productId = productCatalog.random()["id"];
          let cart = sut.api.http.post("/api/carts", { "items": [{ "productId": productId, "quantity": 1 }] });
          assert cart.status == 201;
          let order = sut.api.http.post("/api/orders", { "cartId": cart.body["cartId"] });
          assert order.status == 201;
          """,
          verify: "assert errors.rate() < 2%;"
        )

      result = run(source)
      assert result.exit_code == 0
      assert totals(result).requests == 36

      requests = TestServer.requests(server)
      orders = Enum.filter(requests, &(&1.path == "/api/orders"))
      carts = Enum.filter(requests, &(&1.path == "/api/carts"))
      assert length(orders) == 12
      assert Enum.all?(orders, &(JSON.decode!(&1.body) == %{"cartId" => "c-1"}))
      assert Enum.all?(carts, &(&1.headers["content-type"] == "application/json"))
      assert Enum.all?(carts, &(hd(JSON.decode!(&1.body)["items"])["productId"] in [7, 8]))
    end

    test "the journey ends at a failed assert, counts it, and Verify decides" do
      server =
        server(fn
          %{path: "/a"} -> 500
          %{path: "/b"} -> 200
        end)

      source =
        suite(server,
          load: "stages [ 1vu for 4iter ]",
          actions: ~S"""
          let a = sut.api.http.get("/a");
          assert a.status == 200;
          sut.api.http.get("/b");
          """,
          verify: "assert errors.rate() < 1%;"
        )

      result = run(source)
      assert TestServer.requests(server) |> Enum.count(&(&1.path == "/b")) == 0
      assert totals(result).requests == 4
      assert totals(result).errors.count == 4
      assert result.exit_code == 1
    end
  end

  describe "failures (C105, C106, C110, C116, C117, C125, C129, C130)" do
    test "a Test with criteria passes despite a failed assert in Actions" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          load: "stages [ 1vu for 3iter ]",
          actions: ~S|let r = sut.api.http.get("/"); assert r.status == 201;|,
          verify:
            "assert errors.count() == 3; assert errors.assertFailures() == 3; assert asserts.failed() == 3;"
        )

      assert run(source).exit_code == 0
    end

    test "a Test without criteria fails on one failed assert in Actions" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          load: "stages [ 1vu for 2iter ]",
          actions: ~S|let r = sut.api.http.get("/"); assert r.status == 201;|
        )

      assert run(source).exit_code == 1
    end

    test "a Verify with only checks has no criteria" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          actions: ~S|let r = sut.api.http.get("/"); assert r.status == 201;|,
          verify: "check errors.count() == 0;"
        )

      assert run(source).exit_code == 1
    end

    test "a failed check stops nothing and never fails the Test" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          load: "stages [ 1vu for 3iter ]",
          actions: ~S"""
          let r = sut.api.http.get("/a");
          check r.status == 201;
          sut.api.http.get("/b");
          """,
          verify: "assert errors.checkFailures() == 3; assert checks.failed() == 3;"
        )

      assert run(source).exit_code == 0
      assert Enum.count(TestServer.requests(server), &(&1.path == "/b")) == 3
    end

    test "a status of 400 or above is failed, below is ok" do
      server =
        server(fn
          %{path: "/r"} -> 302
          %{path: "/n"} -> 404
        end)

      source =
        suite(server,
          actions: ~S"""
          let r = sut.api.http.get("/r");
          assert r.outcome == "ok";
          let n = sut.api.http.get("/n");
          assert n.outcome == "failed";
          assert n.status == 404;
          """,
          verify: "assert errors.count() == 1;"
        )

      assert run(source).exit_code == 0
    end

    test "a redirect is not followed (C170)" do
      server = server(fn %{path: "/from"} -> 302 end)
      source = suite(server, actions: ~S|let r = sut.api.http.get("/from"); assert r.status == 302;|)
      assert run(source).exit_code == 0
      assert length(TestServer.requests(server)) == 1
    end

    test "a timeout has status 0, counts as an error, and has no latency (C108, C110)" do
      server = server(fn _ -> {:sleep, 300, 200} end)

      source =
        suite(server,
          load: "requestTimeout 50ms;",
          actions: ~S"""
          let r = sut.api.http.get("/slow");
          assert r.outcome == "timeout";
          assert r.status == 0;
          """,
          verify: "assert errors.timeouts() == 1; assert errors.count() == 1;"
        )

      result = run(source)
      assert result.exit_code == 0
      assert totals(result).latency == nil
    end

    test "a connection error has status 0" do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      source = """
      TestSuite S {
        Config { sut { api { baseUrl = "http://127.0.0.1:#{port}"; } } }
        Test T {
          Load { }
          Actions {
            let r = sut.api.http.get("/");
            assert r.outcome == "connectionError";
            assert r.status == 0;
          }
          Verify { assert errors.connectionErrors() == 1; }
        }
      }
      """

      assert run(source).exit_code == 0
    end

    test "a target with no baseUrl through a Target value gives connectionError (C156)" do
      source = """
      TestSuite S {
        Config { sut { db { host = "10.0.0.1"; } } }
        Test T {
          Load { }
          Actions {
            let t = sut.db;
            let r = t.http.get("/");
            assert r.outcome == "connectionError";
          }
          Verify { assert errors.count() == 1; }
        }
      }
      """

      assert run(source).exit_code == 0
    end
  end

  describe "Json (C110, C141)" do
    test "a missing key ends the iteration as a failed assert" do
      server = server(fn _ -> {200, %{"a" => 1}} end)

      source =
        suite(server,
          load: "stages [ 1vu for 2iter ]",
          actions: ~S"""
          let r = sut.api.http.get("/");
          let b = r.body["missing"];
          sut.api.http.get("/never");
          """,
          verify: "assert asserts.failed() == 2; assert errors.assertFailures() == 2;"
        )

      assert run(source).exit_code == 0
      refute Enum.any?(TestServer.requests(server), &(&1.path == "/never"))
    end

    test "a body that is not JSON is null, so indexing it fails" do
      server = server(fn _ -> {200, "plain text"} end)

      source =
        suite(server,
          actions: ~S|let r = sut.api.http.get("/"); let b = r.body["x"];|,
          verify: "assert asserts.failed() == 1;"
        )

      assert run(source).exit_code == 0
    end

    test "conversions are checked when used" do
      server = server(fn _ -> {200, %{"n" => 5, "s" => "x", "f" => 1.5}} end)

      source =
        suite(server,
          actions: ~S"""
          let r = sut.api.http.get("/");
          assert r.body["n"] > 4;
          assert r.body["s"] == "x";
          let n: Int = r.body["n"];
          let f: Float = r.body["n"];
          assert f == 5.0;
          let path = "/items/" + r.body["s"];
          sut.api.http.get(path);
          let bad: Int = r.body["f"];
          sut.api.http.get("/never");
          """,
          verify: "assert asserts.failed() == 1;"
        )

      assert run(source).exit_code == 0
      paths = Enum.map(TestServer.requests(server), & &1.path)
      assert "/items/x" in paths
      refute "/never" in paths
    end

    test "a failed assert with no value stops the rest of Verify" do
      server = server(fn _ -> {200, %{}} end)

      source =
        suite(server,
          actions: ~S|sut.api.http.get("/");|,
          verify: ~S"""
          let r = sut.api.http.get("/v");
          let x = r.body["missing"];
          sut.api.http.get("/never");
          """
        )

      assert run(source).exit_code == 1
      refute Enum.any?(TestServer.requests(server), &(&1.path == "/never"))
    end
  end

  describe "values (C142-C145, C171)" do
    test "the built-ins and operators work" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          actions: ~S"""
          assert 2 + 3 == 5;
          assert 4 / 2 == 2.0;
          assert 2 ^ 3 == 8.0;
          assert 5s + 500ms == 5500ms;
          assert 1000ms == 1s;
          assert 2 * 5s == 10s;
          assert 10s / 2s == 5.0;
          assert 10J / 2s == 5W;
          assert 5W * 2s == 10J;
          assert min(1s, 2s) == 1s;
          assert max(1, 2.5) == 2.5;
          assert sqrt(16) == 4.0;
          assert range(0, 3) == [0, 1, 2];
          assert [1, 2, 3].length() == 3;
          assert [1, 2].contains(2);
          assert ![1, 2].contains(3);
          assert [1, 2, 3].map(\x -> x * 2) == [2, 4, 6];
          assert [1, 2, 3].filter(\x -> x > 1) == [2, 3];
          assert [1, 2, 3].fold(0, \(sum, x) -> sum + x) == 6;
          assert ["a", "b"].foldr("", \(x, acc) -> x + acc) == "ab";
          assert "a" + "b" == "ab";
          let picks = [1, 2, 3, 4, 5].random(5);
          assert picks.fold(0, \(sum, x) -> sum + x) == 15;
          assert [1, 2, 3].random(0).length() == 0;
          let kind = match 5 { 1 => "one", n if n > 3 => "big", _ => "small" };
          assert kind == "big";
          """,
          verify: "assert asserts.failed() == 0;"
        )

      assert run(source).exit_code == 0
    end

    test "toString gives the text of a value (C177)" do
      body = %{"id" => 42, "name" => "Lamp", "price" => 2.0, "tags" => ["a", "b"], "ok" => true}
      server = server(fn _ -> {200, body} end)

      source =
        suite(server,
          actions: ~S"""
          assert (42).toString() == "42";
          assert (-7).toString() == "-7";
          assert (2.0).toString() == "2.0";
          assert (1.5).toString() == "1.5";
          assert (1 / 4).toString() == "0.25";
          assert max(1, 2.5).toString() == "2.5";
          assert min(1, 2.5).toString() == "1.0";
          let mut f = 1.5;
          f = 3;
          assert f.toString() == "3.0";
          assert true.toString() == "true";
          assert "a".toString() == "a";
          assert 1.5s.toString() == "1500ms";
          assert (1s / 3).toString() == "333.333ms";
          assert 1kWh.toString() == "3600000J";
          assert 2.5W.toString() == "2.5W";
          assert 3gCO2e.toString() == "3gCO2e";
          assert 33.33%.toString() == "33.33%";
          assert 50vu.toString() == "50vu";
          let r = sut.api.http.get("/item");
          assert r.status.toString() == "200";
          assert r.body["id"].toString() == "42";
          assert r.body["name"].toString() == "Lamp";
          assert r.body["price"].toString() == "2.0";
          assert r.body["ok"].toString() == "true";
          assert r.body["tags"].toString() == "[\"a\",\"b\"]";
          assert "/api/items/" + r.body["id"].toString() == "/api/items/42";
          assert "username_" + range(5, 6).random().toString() == "username_5";
          """,
          verify: ~S"""
          assert asserts.failed() == 0;
          check latency.p95().toString() != "";
          """
        )

      assert run(source).exit_code == 0
    end

    test "toString of JSON null is a failed assert with no value (C177)" do
      server = server(fn _ -> {200, %{"id" => nil}} end)

      source =
        suite(server,
          actions: ~S"""
          let r = sut.api.http.get("/item");
          let id = r.body["id"].toString();
          sut.api.http.get("/never");
          """,
          verify: "assert asserts.failed() == 1;"
        )

      assert run(source).exit_code == 0
      refute Enum.any?(TestServer.requests(server), &(&1.path == "/never"))
    end

    test "functions, recursion and lambdas" do
      server = server(fn _ -> 200 end)

      source = """
      TestSuite S {
        #{config(server)}
        Functions {
          fn fact(n: Int): Int {
            if n <= 1 { return 1; }
            return n * fact(n - 1);
          }
          fn twice(f: Fn<Int, Int>, x: Int): Int { return f(f(x)); }
          fn get(t: Target): Response { return t.http.get("/x"); }
        }
        Test T {
          Load { }
          Actions {
            assert fact(5) == 120;
            let limit = 2;
            assert twice(\\x -> x + limit, 1) == 5;
            assert get(sut.api).status == 200;
            let mut n = 0;
            for i in range(0, 3) { n = n + i; }
            while n < 5 { n = n + 1; }
            assert n == 5;
          }
          Verify { assert asserts.failed() == 0; assert errors.count() == 0; }
        }
      }
      """

      assert run(source).exit_code == 0
    end

    test "run-time value errors are failed asserts (C171)" do
      server = server(fn _ -> 200 end)

      for statement <- [
            "let a = 1 / 0;",
            "let a = [1][5];",
            "let a = log(0);",
            "let p = 0s - 1s; sleep(p);",
            "let a = [1].random(2);",
            "let a: List<Int> = []; let b = a.random();"
          ] do
        source =
          suite(server,
            actions: statement <> ~S| sut.api.http.get("/never");|,
            verify: "assert asserts.failed() == 1;"
          )

        assert run(source).exit_code == 0, statement
      end

      refute Enum.any?(TestServer.requests(server), &(&1.path == "/never"))
    end
  end

  describe "stages (C103, C127, C128, C169)" do
    test "a count stage starts exactly that many iterations" do
      server = server(fn _ -> {:sleep, 2, 200} end)
      source = suite(server, load: "stages [ 5vu for 23iter ]", actions: ~S|sut.api.http.get("/");|)
      result = run(source)
      assert totals(result).requests == 23
      assert length(TestServer.requests(server)) == 23
    end

    test "a count per user gives each user exactly its share (C175)" do
      server = server(fn _ -> {:sleep, 5, 200} end)
      file = temp("users.jsonl")

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; fields = [virtualUser, iteration]; } }|,
          load: "stages [ 20vu for 1iter/vu ]",
          actions: ~S|sut.api.http.get("/");|
        )

      run(source)
      lines = file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      assert lines |> Enum.map(& &1["virtualUser"]) |> Enum.sort() == Enum.to_list(1..20)
      assert Enum.all?(lines, &(&1["iteration"] == 1))
    end

    test "a count per user holds when one user is slower than the others (C175)" do
      # The first request is slow. With a shared count the other users take
      # its iterations; with a count per user every user runs 4.
      first = :atomics.new(1, [])

      server =
        server(fn _ ->
          if :atomics.add_get(first, 1, 1) == 1, do: {:sleep, 300, 200}, else: 200
        end)

      file = temp("slow.jsonl")

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; fields = [virtualUser]; } }|,
          load: "stages [ 3vu for 4iter/vu ]",
          actions: ~S|sut.api.http.get("/");|
        )

      run(source)
      lines = file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      assert lines |> Enum.frequencies_by(& &1["virtualUser"]) == %{1 => 4, 2 => 4, 3 => 4}
    end

    test "a count per user is per stage, and new users join (C175)" do
      server = server(fn _ -> 200 end)
      file = temp("stages.jsonl")

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; fields = [virtualUser]; } }|,
          load: "stages [ 2vu for 2iter/vu, 4vu for 1iter/vu ]",
          actions: ~S|sut.api.http.get("/");|
        )

      run(source)
      lines = file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      assert lines |> Enum.frequencies_by(& &1["virtualUser"]) == %{1 => 3, 2 => 3, 3 => 1, 4 => 1}
    end

    test "no iteration runs between two count stages (C103)" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          load: "stages [ 50vu for 50iter, 50vu for 50iter, 50vu for 50iter ]",
          actions: ~S|sut.api.http.get("/");|
        )

      result = run(source)
      assert totals(result).requests == 150
      assert length(TestServer.requests(server)) == 150
    end

    test "all users start at once in a hold stage" do
      server = server(fn _ -> {:sleep, 100, 200} end)
      source = suite(server, load: "stages [ 10vu for 10iter ]", actions: ~S|sut.api.http.get("/");|)
      started = System.monotonic_time(:millisecond)
      run(source)
      assert System.monotonic_time(:millisecond) - started < 600
    end

    test "a time stage lasts its time" do
      server = server(fn _ -> 200 end)

      source =
        suite(server, load: "thinkTime 20ms; stages [ 2vu for 300ms ]", actions: ~S|sut.api.http.get("/");|)

      started = System.monotonic_time(:millisecond)
      result = run(source)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 300 and elapsed < 900
      assert totals(result).requests > 5
    end

    test "a ramp raises the users, and now stages change them at once" do
      server = server(fn _ -> {:sleep, 5, 200} end)
      file = temp("ramp.jsonl")

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; fields = [virtualUser]; } }|,
          load: "stages [ 2vu now, 6vu in 200ms, 6vu for 100ms, 0vu in 100ms ]",
          actions: ~S|sut.api.http.get("/");|
        )

      run(source)

      users =
        file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!(&1)["virtualUser"])

      assert Enum.max(users) == 6
    end

    test "a user ends after its current request, which counts" do
      server = server(fn _ -> {:sleep, 150, 200} end)
      source = suite(server, load: "stages [ 1vu for 50ms ]", actions: ~S|sut.api.http.get("/");|)
      result = run(source)
      assert totals(result).requests == 1
      assert totals(result).errors.count == 0
    end

    test "the run waits for a user a stage took away, and its request counts" do
      server = server(fn _ -> {:sleep, 150, 200} end)

      source =
        suite(server, load: "stages [ 2vu for 50ms, 0vu in 10ms ]", actions: ~S|sut.api.http.get("/");|)

      result = run(source)
      assert totals(result).requests == 2
      assert totals(result).errors.count == 0
    end

    test "a ramp by iterations from or to 0 users runs every iteration (C103)" do
      server = server(fn _ -> {:sleep, 2, 200} end)
      up = suite(server, load: "stages [ 3vu in 30iter ]", actions: ~S|sut.api.http.get("/up");|)
      down = suite(server, load: "stages [ 4vu now, 0vu in 30iter ]", actions: ~S|sut.api.http.get("/down");|)

      # A user the ramp down takes away between claiming an iteration and its
      # request ends that iteration with no request; the iteration still started.
      for {source, path, sent} <- [{up, "/up", 30..30}, {down, "/down", 26..30}] do
        task = Task.async(fn -> run(source) end)
        assert {:ok, %{exit_code: 0}} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
        assert Enum.count(TestServer.requests(server), &(&1.path == path)) in sent
      end
    end

    test "no stages is one user and one iteration (C124)" do
      server = server(fn _ -> 200 end)
      assert totals(run(suite(server, actions: ~S|sut.api.http.get("/");|))).requests == 1
    end

    test "curves shape a ramp" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          load:
            "curves { up(t) = t^2; wave(t, n) = t * n; } stages [ 3vu in 100ms up, 5vu in 100ms exp, 2vu in 100ms wave(1) ]",
          actions: ~S|sut.api.http.get("/");|
        )

      assert run(source).status == :ok
    end
  end

  describe "think time, connections, retries (C16, C38, C86, C170)" do
    test "a user waits after every response, in and across iterations" do
      server = server(fn _ -> 200 end)
      file = temp("think.jsonl")

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; fields = [time]; } }|,
          load: "thinkTime 40ms; stages [ 1vu for 2iter ]",
          actions: ~S|sut.api.http.get("/a"); sut.api.http.get("/b");|
        )

      run(source)

      times =
        file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&(DateTime.from_iso8601(JSON.decode!(&1)["time"]) |> elem(1)))

      gaps =
        times
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> DateTime.diff(b, a, :millisecond) end)

      assert length(gaps) == 3
      assert Enum.all?(gaps, &(&1 >= 39))
    end

    test "Setup does not wait" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          load: "thinkTime 500ms;",
          setup: ~S|sut.api.http.get("/a"); sut.api.http.get("/b"); sut.api.http.get("/c");|,
          actions: ""
        )

      started = System.monotonic_time(:millisecond)
      run(source)
      assert System.monotonic_time(:millisecond) - started < 400
    end

    test "each user keeps one connection" do
      server = server(fn _ -> 200 end)
      source = suite(server, load: "stages [ 4vu for 40iter ]", actions: ~S|sut.api.http.get("/");|)
      run(source)
      assert TestServer.connections(server) == 4
    end

    test "a closed connection is reopened, and no failure" do
      counter = :counters.new(1, [])

      server =
        server(fn _ ->
          :counters.add(counter, 1, 1)
          if rem(:counters.get(counter, 1), 2) == 0, do: :close, else: 200
        end)

      source =
        suite(server,
          load: "stages [ 1vu for 4iter ]",
          actions: ~S|sut.api.http.get("/");|,
          verify: "assert errors.count() == 0;"
        )

      assert run(source).exit_code == 0
    end

    test "attempts counts the first try; 5xx retries, a retried request counts once" do
      counter = :counters.new(1, [])

      server =
        server(fn _ ->
          :counters.add(counter, 1, 1)
          if :counters.get(counter, 1) < 3, do: 503, else: 200
        end)

      source =
        suite(server,
          load: "retry { attempts 3; delay 1ms; backoff fixed; }",
          actions: ~S|let r = sut.api.http.get("/"); assert r.status == 200;|,
          verify: "assert errors.count() == 0;"
        )

      result = run(source)
      assert result.exit_code == 0
      assert length(TestServer.requests(server)) == 3
      assert totals(result).requests == 1
    end

    test "4xx does not retry, and attempts run out" do
      server =
        server(fn
          %{path: "/gone"} -> 404
          %{path: "/down"} -> 500
        end)

      source =
        suite(server,
          load: "retry { attempts 2; delay 1ms; }",
          actions: ~S|sut.api.http.get("/gone"); sut.api.http.get("/down");|
        )

      run(source)
      paths = Enum.map(TestServer.requests(server), & &1.path)
      assert Enum.count(paths, &(&1 == "/gone")) == 1
      assert Enum.count(paths, &(&1 == "/down")) == 2
    end

    test "exponential doubles the delay" do
      server = server(fn _ -> 500 end)

      source =
        suite(server,
          load: "retry { attempts 3; delay 50ms; backoff exponential; }",
          actions: ~S|sut.api.http.get("/");|
        )

      started = System.monotonic_time(:millisecond)
      run(source)
      assert System.monotonic_time(:millisecond) - started >= 150
    end
  end

  describe "http details (C113, C115, C123)" do
    test "bodies, headers and queries" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          actions: ~S"""
          sut.api.http.post("/json", { "a": 1 });
          sut.api.http.post("/text", "hello");
          sut.api.http.post("/empty", "", { "headers": { "X-Trace": "1" } });
          sut.api.http.post("/override", "{}", { "headers": { "Content-Type": "application/json" } });
          sut.api.http.get("/query", { "query": { "page": 2, "q": "a b" } });
          sut.api.http.put("/put", [1, 2]);
          sut.api.http.patch("/patch", 5);
          sut.api.http.delete("/delete");
          sut.api.http.head("/head");
          """
        )

      run(source)
      requests = Map.new(TestServer.requests(server), &{&1.path, &1})
      assert requests["/json"].headers["content-type"] == "application/json"
      assert requests["/json"].body == ~s({"a":1})
      assert requests["/text"].headers["content-type"] == "text/plain; charset=utf-8"
      assert requests["/empty"].body == ""
      assert requests["/empty"].headers["x-trace"] == "1"
      refute Map.has_key?(requests["/empty"].headers, "content-type")
      assert requests["/override"].headers["content-type"] == "application/json"
      assert requests["/query"].query in ["page=2&q=a+b", "q=a+b&page=2"]
      assert requests["/put"].method == "PUT"
      assert requests["/put"].body == "[1,2]"
      assert requests["/patch"].body == "5"
      assert requests["/delete"].method == "DELETE"
      assert requests["/head"].method == "HEAD"
    end

    test "standalone http takes a full URL" do
      server = server(fn _ -> 200 end)

      source = """
      TestSuite S {
        Test T { Load { } Actions { let r = http.get("#{server.url}/health"); assert r.status == 200; } }
      }
      """

      assert run(source).exit_code == 0
      assert [%{path: "/health"}] = TestServer.requests(server)
    end

    test "a response has its headers, lower case" do
      server = server(fn _ -> {200, %{"a" => 1}} end)

      source =
        suite(server,
          actions: ~S|let r = sut.api.http.get("/"); assert r.headers["content-type"] == "application/json";|
        )

      assert run(source).exit_code == 0
    end
  end

  describe "phases (C116, C136, C137, C155)" do
    test "a failed assert in Setup skips Actions and Verify, and Cleanup still runs" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          setup: ~S"""
          let token = "t-1";
          sut.api.http.get("/setup");
          assert false;
          sut.api.http.get("/never");
          """,
          actions: ~S|sut.api.http.get("/actions");|,
          verify: ~S|sut.api.http.get("/verify");|,
          cleanup: ~S|sut.api.http.post("/cleanup", token);|
        )

      assert run(source).exit_code == 1
      assert [%{path: "/setup"}, %{path: "/cleanup", body: "t-1"}] = TestServer.requests(server)
    end

    test "a failed assert in Cleanup fails the Test, and the rest runs" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          actions: "",
          verify: "assert true;",
          cleanup: ~S|assert false; sut.api.http.get("/after");|
        )

      assert run(source).exit_code == 1
      assert [%{path: "/after"}] = TestServer.requests(server)
    end

    test "every Verify assert is evaluated and reported" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          actions: ~S|sut.api.http.get("/");|,
          verify: "assert errors.count() == 5; assert errors.count() == 0;"
        )

      result = run(source)
      assert result.exit_code == 1
      assert [%{passed: false, source: "errors.count() == 5"}, %{passed: true}] = hd(tests(result)).verify
    end

    test "a shared list collects from every user, and later phases read it" do
      counter = :counters.new(1, [])

      server =
        server(fn
          %{method: "GET", path: "/api/products"} ->
            {200, %{"products" => Enum.map(1..8, &%{"id" => &1})}}

          %{method: "POST", path: "/api/carts"} ->
            :counters.add(counter, 1, 1)
            {201, %{"cartId" => "cart-#{:counters.get(counter, 1)}"}}

          %{method: "GET", path: "/api/carts"} ->
            {200, %{"carts" => Enum.map(1..20, &%{"cartId" => "cart-#{&1}"})}}

          %{method: "DELETE"} ->
            204
        end)

      source =
        suite(server,
          load: "requestTimeout 5s; stages [ 20vu for 1iter/vu ]",
          setup: ~S"""
          let products = sut.api.http.get("/api/products");
          assert products.status == 200;
          let availableProducts = products.body["products"];
          let mut cartIdList = [];
          """,
          actions: ~S"""
          let picks = availableProducts.random(5);
          let cart = sut.api.http.post("/api/carts", { "items": picks.map(\p -> { "productId": p["id"], "quantity": 1 }) });
          assert cart.status == 201;
          cartIdList.add(cart.body["cartId"]);
          """,
          verify: ~S"""
          let carts = sut.api.http.get("/api/carts");
          assert carts.status == 200;
          let listed = carts.body["carts"].map(\c -> c["cartId"]);
          assert cartIdList.length() == 20;
          for id in cartIdList { assert listed.contains(id); }
          """,
          cleanup: ~S"""
          for id in cartIdList {
            let response = sut.api.http.delete("/api/carts/" + id);
            assert response.status == 204;
          }
          """
        )

      result = run(source)
      assert result.exit_code == 0
      assert totals(result).requests == 20

      requests = TestServer.requests(server)
      assert Enum.count(requests, &(&1.method == "DELETE")) == 20
      posts = Enum.filter(requests, &(&1.method == "POST"))

      for post <- posts do
        ids = JSON.decode!(post.body)["items"] |> Enum.map(& &1["productId"])
        assert length(Enum.uniq(ids)) == 5
      end
    end

    test "an Actions variable reaches Verify and Cleanup; one that was never set is no value" do
      server = server(fn _ -> {200, %{"n" => 1}} end)

      source =
        suite(server,
          actions: ~S|let r = sut.api.http.get("/");|,
          verify: ~S|assert r.status == 200;|,
          cleanup: ~S|assert r.body["n"] == 1;|
        )

      assert run(source).exit_code == 0

      source =
        suite(server,
          actions: ~S|assert false; let r = sut.api.http.get("/");|,
          verify: ~S|assert r.status == 200; assert true;|
        )

      result = run(source)
      assert result.exit_code == 1
      assert [%{passed: false}] = hd(tests(result)).verify
    end
  end

  describe "metrics (C60, C104, C107, C108, C135, C172)" do
    test "only Actions requests count, without warmup" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          load: "warmup 100ms; thinkTime 10ms; stages [ 1vu for 300ms ]",
          setup: ~S|sut.api.http.get("/setup");|,
          actions: ~S|sut.api.http.get("/actions");|,
          verify: ~S|sut.api.http.get("/verify"); assert errors.count() == 0;|,
          cleanup: ~S|sut.api.http.get("/cleanup");|
        )

      result = run(source)
      actions = Enum.count(TestServer.requests(server), &(&1.path == "/actions"))
      assert totals(result).requests > 0
      assert totals(result).requests < actions
      assert hd(tests(result)).snapshot.endpoints |> Enum.map(& &1.url) == ["/actions"]
    end

    test "each endpoint is reported" do
      server =
        server(fn
          %{path: "/a"} -> 200
          %{path: "/b"} -> 500
        end)

      source =
        suite(server,
          load: "stages [ 2vu for 6iter ]",
          actions: ~S|sut.api.http.get("/a?x=1"); sut.api.http.get("/b");|
        )

      [a, b] = hd(tests(run(source))).snapshot.endpoints
      assert %{url: "/a?x=1", method: "GET", target: "api", requests: 6} = a
      assert a.errors.rate == 0.0
      assert %{url: "/b", requests: 6} = b
      assert b.errors.rate == 100.0
    end

    test "a latency metric with no response is a failed assert with no value (C174)" do
      server = server(fn _ -> 200 end)
      source = suite(server, actions: "", verify: "assert latency.p95() < 1s;")
      assert run(source).exit_code == 1
    end

    test "latency metrics and throughput read the records" do
      server = server(fn _ -> {:sleep, 20, 200} end)

      source =
        suite(server,
          load: "stages [ 1vu for 300ms ]",
          actions: ~S|sut.api.http.get("/");|,
          verify: """
          assert latency.p50() >= 19ms;
          assert latency.max() >= latency.min();
          assert latency.percentile(100) == latency.max();
          assert throughput.perSecond() > 1;
          """
        )

      assert run(source).exit_code == 0
    end

    test "a percentile is exact, by nearest rank" do
      alias Aetherion.Recorder
      sorted = Enum.to_list(1..100)
      assert Recorder.percentile(sorted, 50) == 50
      assert Recorder.percentile(sorted, 95) == 95
      assert Recorder.percentile(sorted, 99.9) == 100
      assert Recorder.percentile(sorted, 0) == 1
    end
  end

  describe "stopIf (C58, C166)" do
    test "ends its Test, Verify still runs, and the next Test runs" do
      server = server(fn _ -> 500 end)

      source = """
      TestSuite S {
        #{config(server)}
        Test First {
          Load { stopIf errors.rate() > 50%; stages [ 1vu for 30s ] }
          Actions { sut.api.http.get("/first"); }
          Verify { assert errors.rate() > 50%; }
        }
        Test Second {
          Load { }
          Actions { sut.api.http.get("/second"); }
        }
      }
      """

      started = System.monotonic_time(:millisecond)
      result = run(source)
      assert System.monotonic_time(:millisecond) - started < 5000
      assert [first, second] = tests(result)
      assert first.stopped_by == "errors.rate() > 50%"
      assert first.result == :passed
      assert second.snapshot.totals.requests == 1
    end

    test "reads latency and counters during the run" do
      server = server(fn _ -> {:sleep, 5, 200} end)

      source = """
      TestSuite S {
        #{config(server)}
        Test T {
          Load { stopIf latency.p95() > 1ms && errors.count() == 0 && throughput.perSecond() > 1; stages [ 1vu for 30s ] }
          Actions { sut.api.http.get("/"); }
        }
      }
      """

      started = System.monotonic_time(:millisecond)
      result = run(source)
      assert System.monotonic_time(:millisecond) - started < 5000
      assert hd(tests(result)).stopped_by =~ "latency.p95()"
    end

    test "does not delay the end of a stage" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          load: "stopIf errors.rate() > 50%; stages [ 20vu for 1500ms ]",
          actions: ~S|sut.api.http.get("/");|
        )

      started = System.monotonic_time(:millisecond)
      run(source)
      assert System.monotonic_time(:millisecond) - started < 2500
    end

    test "Tests run one at a time, with their own metrics" do
      server = server(fn _ -> 200 end)

      source = """
      TestSuite S {
        #{config(server)}
        Load { stages [ 1vu for 2iter ] }
        Test A { Actions { sut.api.http.get("/a"); } Verify { assert errors.count() == 0; } }
        Test B { Actions { sut.api.http.get("/b"); } }
      }
      """

      result = run(source)
      assert Enum.map(tests(result), & &1.snapshot.totals.requests) == [2, 2]
      paths = Enum.map(TestServer.requests(server), & &1.path)
      assert paths == ["/a", "/a", "/b", "/b"]
    end
  end

  describe "distribution and the seed (C165, C168)" do
    defp two_servers do
      {server(fn _ -> 200 end), server(fn _ -> 200 end)}
    end

    defp any_suite(a, b) do
      """
      TestSuite S {
        Config { sut { a { baseUrl = "#{a.url}"; } b { baseUrl = "#{b.url}"; } } }
        Test T {
          Load { stages [ 1vu for 400iter ] distribution { a 75%; b 25%; } }
          Actions { sut.any.http.get("/one"); sut.any.http.get("/two"); }
        }
      }
      """
    end

    test "sut.any splits by the percentages, and stays on one target for an iteration" do
      {a, b} = two_servers()
      run(any_suite(a, b), seed: 7)

      a_count = length(TestServer.requests(a))
      b_count = length(TestServer.requests(b))
      assert a_count + b_count == 800
      assert rem(a_count, 2) == 0 and rem(b_count, 2) == 0
      assert a_count > 480 and a_count < 720
    end

    test "the same seed makes the same choices" do
      {a, b} = two_servers()
      run(any_suite(a, b), seed: 7)
      first = length(TestServer.requests(a))
      run(any_suite(a, b), seed: 7)
      assert length(TestServer.requests(a)) == first * 2
    end

    test "a seed is picked, and kept in the result" do
      server = server(fn _ -> 200 end)
      result = run(suite(server, actions: ""))
      assert is_integer(result.seed)
    end
  end

  describe "files (C119-C122, C173)" do
    defp attempt(at, warmup),
      do: %{
        at: at,
        phase: "Actions",
        last: true,
        warmup: warmup,
        outcome: "ok",
        latency: 1.0,
        target: nil,
        method: "GET",
        path: "/"
      }

    test "a recorder keeps the attempts the requests file needs, and gives them in time order" do
      alias Aetherion.Recorder

      none = Recorder.new(requests: :none)
      measured = Recorder.new(requests: :measured)
      all = Recorder.new(requests: :all)

      # Each the last attempt of its request, so the two outside warmup count.
      for recorder <- [none, measured, all], {at, warmup} <- [{30.0, false}, {10.0, true}, {20.0, false}] do
        Recorder.attempt(recorder, attempt(at, warmup), true)
        Recorder.flush()
      end

      assert Recorder.take_requests(none, :infinity) == []
      assert measured |> Recorder.take_requests(:infinity) |> Enum.map(& &1.at) == [20.0, 30.0]

      # Before a watermark, and what is left stays for the next call.
      assert all |> Recorder.take_requests(25.0) |> Enum.map(& &1.at) == [10.0, 20.0]
      assert all |> Recorder.take_requests(:infinity) |> Enum.map(& &1.at) == [30.0]
      assert Recorder.take_requests(all, :infinity) == []

      # Metrics do not depend on the requests file.
      assert Recorder.snapshot(none).totals.requests == 2
    end

    test "the requests file is written during the Test, not only at its end" do
      server = server(fn _ -> {:sleep, 2, 200} end)
      file = temp("streamed.jsonl")

      # The window is requestTimeout + 2s, so attempts go out after about 2.2s.
      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; fields = [time]; } }|,
          load: "requestTimeout 200ms; stages [ 2vu for 4s ]",
          actions: ~S|sut.api.http.get("/");|
        )

      task = Task.async(fn -> run(source) end)
      Process.sleep(3200)
      assert Task.yield(task, 0) == nil
      written = file |> File.read!() |> String.split("\n", trim: true) |> length()
      assert written > 0

      assert %{exit_code: 0} = Task.await(task, 10_000)
      lines = file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      assert length(lines) > written
      assert length(lines) == length(TestServer.requests(server))
      times = Enum.map(lines, & &1["time"])
      assert times == Enum.sort(times)
    end

    test "the requests file holds every phase, in the fields of C120" do
      server = server(fn _ -> 200 end)
      file = temp("deep/requests.jsonl")

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; } }|,
          setup: ~S|sut.api.http.get("/setup");|,
          actions: ~S|sut.api.http.get("/actions");|
        )

      run(source)
      [setup, actions] = file |> File.read!() |> String.split("\n", trim: true)
      assert {:ok, %{"phase" => "Setup", "url" => "/setup", "status" => 200}} = JSON.decode(setup)

      assert %{"phase" => "Actions", "virtualUser" => 1, "iteration" => 1, "outcome" => "ok", "attempt" => 1} =
               JSON.decode!(actions)

      assert String.starts_with?(setup, ~s({"time":))
      assert %{"target" => "api", "method" => "GET", "test" => "T"} = JSON.decode!(actions)
    end

    test "fields picks the fields, in the order of C120, and warmup needs includeWarmup" do
      server = server(fn _ -> 200 end)
      file = temp("fields.jsonl")

      source =
        suite(server,
          output:
            ~s|output { requests { file = "#{file}"; fields = [outcome, status]; includeWarmup = true; } }|,
          load: "warmup 100ms; stages [ 1vu for 50ms, 1vu for 1iter ]",
          actions: ~S|sut.api.http.get("/");|
        )

      run(source)
      first = file |> File.read!() |> String.split("\n", trim: true) |> hd()
      assert first == ~s({"status":200,"outcome":"ok","warmup":true})
    end

    test "an existing file is kept" do
      server = server(fn _ -> 200 end)
      file = temp("keep.jsonl")
      File.write!(file, "old\n")

      source =
        suite(server,
          output: ~s|output { requests { file = "#{file}"; } }|,
          actions: ~S|sut.api.http.get("/");|
        )

      run(source)
      assert File.read!(file) == "old\n"
      assert [_new] = Path.wildcard(Path.rootname(file) <> "-*.jsonl")
    end

    test "the summary follows the README layout" do
      server = server(fn _ -> 200 end)
      file = temp("summary.json")

      source =
        suite(server,
          output: ~s|output { summary = "#{file}"; }|,
          load: "stages [ 1vu for 2iter ]",
          actions: ~S|sut.api.http.get("/a");|,
          verify: "assert errors.rate() < 2%;"
        )

      run(source, seed: 42)
      summary = file |> File.read!() |> JSON.decode!()

      assert %{
               "version" => 4,
               "suite" => "S",
               "seed" => 42,
               "result" => "passed",
               "experiment" => %{"count" => 1, "discard" => 0, "cooldownMs" => 0},
               "runs" => [
                 %{"run" => 1, "seed" => 42, "discarded" => false, "result" => "passed", "tests" => [test]}
               ],
               "tests" => [%{"name" => "T", "result" => "passed", "runs" => runs, "aggregate" => aggregate}]
             } = summary

      assert runs == %{"counted" => 1, "passed" => 1, "failed" => 0}

      # One run: a description with n = 1 and no spread (C180).
      assert %{"n" => 1, "mean" => 2.0, "sd" => nil, "ci95" => nil} = aggregate["metrics"]["requests"]
      assert [%{"target" => "api", "url" => "/a", "requests" => %{"n" => 1}}] = aggregate["endpoints"]

      assert %{"name" => "T", "result" => "passed", "stoppedBy" => nil} = test
      # One machine: no workers, and the load generator is this one (C160, C183).
      assert %{"workers" => [], "loadGenerator" => %{"cpu" => _, "mem" => _}} = test
      assert aggregate["workers"] == []

      assert %{"requests" => 2, "errors" => %{"rate" => +0.0, "count" => 0}, "latency" => %{"p95" => _}} =
               test["metrics"]

      assert [%{"target" => "api", "method" => "GET", "url" => "/a", "requests" => 2}] = test["endpoints"]
      refute Map.has_key?(hd(test["endpoints"]), "latencies")

      assert [%{"kind" => "assert", "source" => "errors.rate() < 2%", "passed" => true, "values" => values}] =
               test["verify"]

      assert values["errors.rate()"] == 0.0
    end
  end

  describe "request metrics per target (C176)" do
    # europe answers 200, unitedStates 500; idle takes requests but gets none.
    defp regions(parts) do
      server =
        server(fn
          %{path: "/fail"} -> 500
          _ -> 200
        end)

      file = temp("regions.json")

      source = """
      TestSuite S {
        Config {
          sut {
            europe       { baseUrl = "#{server.url}"; }
            unitedStates { baseUrl = "#{server.url}"; }
            idle         { baseUrl = "#{server.url}"; }
          }
          output { summary = "#{file}"; }
        }
        Test T {
          Load { stages [ 2vu for 6iter ] }
          Actions {
            sut.europe.http.get("/ok");
            sut.europe.http.get("/ok");
            let r = sut.unitedStates.http.get("/fail");
            check r.status == 200;
          }
          Verify { #{parts[:verify]} }
        }
      }
      """

      result = run(source, Keyword.take(parts, [:report]))
      summary = file |> File.read!() |> JSON.decode!()
      {result, summary |> Map.fetch!("runs") |> hd() |> Map.fetch!("tests") |> hd()}
    end

    test "each target reads only its own requests, so one region can fail alone" do
      {result, test} =
        regions(
          verify: """
          assert sut.europe.errors.rate() < 1%;
          assert sut.europe.latency.p95() < 5s;
          assert sut.unitedStates.errors.rate() < 1%;
          """
        )

      assert result.exit_code == 1

      assert [
               %{"source" => "sut.europe.errors.rate() < 1%", "passed" => true, "values" => europe},
               %{"source" => "sut.europe.latency.p95() < 5s", "passed" => true},
               %{"source" => "sut.unitedStates.errors.rate() < 1%", "passed" => false, "values" => us}
             ] = test["verify"]

      assert europe == %{"sut.europe.errors.rate()" => 0.0}
      assert us == %{"sut.unitedStates.errors.rate()" => 100.0}

      # The totals mix both: 6 of 18 requests failed.
      assert_in_delta test["metrics"]["errors"]["rate"], 100 / 3, 0.01
    end

    test "the summary gives every target that takes requests its request metrics" do
      {_result, test} = regions(verify: "assert errors.count() >= 0;")
      targets = Map.new(test["targets"], &{&1["name"], &1["metrics"]})

      assert %{"requests" => 12, "errors" => %{"rate" => +0.0}, "latency" => %{"p95" => _}} =
               targets["europe"]

      assert %{"requests" => 6, "errors" => %{"rate" => 100.0, "count" => 6}} = targets["unitedStates"]
      assert %{"requests" => 0, "latency" => nil, "errors" => nil} = targets["idle"]
      assert targets["europe"]["throughput"]["perSecond"] > 0
    end

    test "a target with no requests has no value, so its criterion fails" do
      {result, test} = regions(verify: "assert sut.idle.errors.rate() < 1%;")

      assert result.exit_code == 1
      assert [%{"passed" => false, "values" => %{"sut.idle.errors.rate()" => nil}}] = test["verify"]
    end

    test "through a Target value, each region is reported with its value" do
      {_result, test} =
        regions(verify: "for region in [sut.europe, sut.unitedStates] { check region.errors.rate() < 1%; }")

      assert [
               %{"kind" => "check", "passed" => true, "values" => %{"region.errors.rate()" => +0.0}},
               %{"kind" => "check", "passed" => false, "values" => %{"region.errors.rate()" => 100.0}}
             ] = test["verify"]
    end

    test "the console report shows a line per target" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          regions(verify: "assert errors.count() >= 0;", report: true)
        end)

      assert output =~ ~r/  europe: 12 requests, [\d.]+\/s, 0\.00% errors \(0\), p50 [\d.]+ms p95/
      assert output =~ "  unitedStates: 6 requests"
      assert output =~ "  idle: 0 requests"
    end
  end

  describe "agents (C158-C162, C164)" do
    defp agent(body) do
      server(fn
        %{path: "/metrics"} -> {200, body}
        _ -> 200
      end)
    end

    defp prometheus(step) do
      """
      # HELP node_cpu_seconds_total x
      node_cpu_seconds_total{cpu="0",mode="idle"} #{step * 3.0}
      node_cpu_seconds_total{cpu="0",mode="user"} #{step * 1.0}
      node_cpu_seconds_total{cpu="1",mode="idle"} #{step * 1.0}
      node_cpu_seconds_total{cpu="1",mode="user"} #{step * 3.0}
      node_memory_MemTotal_bytes 1000
      node_memory_MemAvailable_bytes 400
      DCGM_FI_DEV_GPU_UTIL{gpu="0"} 10
      DCGM_FI_DEV_GPU_UTIL{gpu="1"} 30
      node_power_watts 120
      """
    end

    defp monitored(api, agent, metrics, extra, verify) do
      """
      TestSuite S {
        Config {
          sut {
            api { baseUrl = "#{api.url}"; }
            box { host = "127.0.0.1"; metricsPort = #{agent.port}; metrics = [#{metrics}]; }
          }
          monitoring { interval = 20ms; format = prometheus; #{extra} }
        }
        Test T {
          Load { thinkTime 10ms; stages [ 1vu for 200ms ] }
          Actions { sut.api.http.get("/"); }
          Verify { #{verify} }
        }
      }
      """
    end

    test "cpu, mem and field metrics are read from a Prometheus agent" do
      steps = :counters.new(1, [])
      :counters.add(steps, 1, 1)

      agent =
        server(fn _ ->
          :counters.add(steps, 1, 1)
          {200, prometheus(:counters.get(steps, 1))}
        end)

      api = server(fn _ -> 200 end)

      source =
        monitored(
          api,
          agent,
          "cpu, mem, gpu[1], power",
          ~s|fields { gpu = "DCGM_FI_DEV_GPU_UTIL"; power = "node_power_watts"; }|,
          """
          assert sut.box.cpu.mean() == 50%;
          assert sut.box.mem.max() == 60%;
          assert sut.box.gpu.max() == 30%;
          assert sut.box.power.mean() == 120W;
          assert sut.mem.mean() == 60%;
          assert power.peak() == 120W;
          assert energy.total() > 0J;
          assert energy.total() < 120J;
          """
        )

      result = run(source)
      assert result.exit_code == 0, inspect(hd(tests(result)).verify)

      assert [%{name: "box", energy: %{source: "agent"}, readings: %{"cpu" => %{samples: samples}}}] =
               hd(tests(result)).targets

      assert samples > 2
    end

    test "the console report shows the readings of each measured target" do
      steps = :counters.new(1, [])

      agent =
        server(fn _ ->
          :counters.add(steps, 1, 1)
          {200, prometheus(:counters.get(steps, 1))}
        end)

      api = server(fn _ -> 200 end)
      fields = ~s|fields { power = "node_power_watts"; }|
      source = monitored(api, agent, "cpu, mem, power", fields, "assert sut.box.cpu.mean() >= 0%;")

      output =
        ExUnit.CaptureIO.capture_io(fn -> assert run(source, report: true).exit_code == 0 end)

      assert output =~ ~r/  box cpu mean 50\.00% max 50\.00% \(\d+ samples\)/
      assert output =~ ~r/  box mem mean 60\.00% max 60\.00% \(\d+ samples\)/
      assert output =~ ~r/  box power mean 120\.00W max 120\.00W \(\d+ samples\)/
      assert output =~ ~r/  box energy [\d.]+J \(agent, \d+ samples\)/

      assert output =~
               ~r/  loadGenerator cpu (mean [\d.]+% max [\d.]+% \(\d+ samples\)|no value \(0 samples\))/

      assert output =~
               ~r/  loadGenerator mem (mean [\d.]+% max [\d.]+% \(\d+ samples\)|no value \(0 samples\))/
    end

    test "cpu selectors narrow the reading (C159)" do
      steps = :counters.new(1, [])

      agent =
        server(fn _ ->
          :counters.add(steps, 1, 1)
          {200, prometheus(:counters.get(steps, 1))}
        end)

      api = server(fn _ -> 200 end)
      assert run(monitored(api, agent, "cpu[0]", "", "assert sut.box.cpu.mean() == 25%;")).exit_code == 0
    end

    test "the load generator is read locally (C160)" do
      api = server(fn _ -> 200 end)

      source = """
      TestSuite S {
        Config { sut { api { baseUrl = "#{api.url}"; } } monitoring { interval = 20ms; } }
        Test T {
          Load { thinkTime 10ms; stages [ 1vu for 200ms ] }
          Actions { sut.api.http.get("/"); }
          Verify { assert loadGenerator.mem.max() > 0%; assert loadGenerator.cpu.max() >= 0%; }
        }
      }
      """

      assert run(source).exit_code == 0
    end

    test "no sample in the window is a failed assert with no value (C164)" do
      dead = server(fn _ -> 500 end)
      api = server(fn _ -> 200 end)
      source = monitored(api, dead, "mem", "", "assert sut.box.mem.max() < 100%; assert true;")
      result = run(source)
      assert result.exit_code == 1
      assert [%{name: "box", readings: %{"mem" => %{samples: 0}}}] = hd(tests(result)).targets
      assert [%{passed: false}] = hd(tests(result)).verify
    end

    test "json agents read dotted paths, narrowed by selectors" do
      agent =
        server(fn _ -> {200, %{"host" => %{"cpu" => [10, 30, 50], "disk" => %{"sda" => 5, "sdb" => 15}}}} end)

      api = server(fn _ -> 200 end)

      source = """
      TestSuite S {
        Config {
          sut {
            api { baseUrl = "#{api.url}"; }
            box { host = "127.0.0.1"; metricsPort = #{agent.port}; metrics = [cpu[0, 1], disk["sdb"]]; }
          }
          monitoring { interval = 20ms; format = json; fields { cpu = "host.cpu"; disk = "host.disk"; } }
        }
        Test T {
          Load { thinkTime 10ms; stages [ 1vu for 150ms ] }
          Actions { sut.api.http.get("/"); }
          Verify { assert sut.box.cpu.mean() == 20%; assert sut.box.disk.max() == 15%; }
        }
      }
      """

      assert run(source).exit_code == 0
    end

    test "the samples file holds every sample, also outside Actions (C162, C173)" do
      agent = agent(prometheus(1))
      api = server(fn _ -> 200 end)
      file = temp("samples.jsonl")

      source = """
      TestSuite S {
        Config {
          sut {
            api { baseUrl = "#{api.url}"; }
            box { host = "127.0.0.1"; metricsPort = #{agent.port}; metrics = [mem]; }
          }
          monitoring { interval = 20ms; format = prometheus; }
          output { samples { file = "#{file}"; } }
        }
        Test T {
          Load { thinkTime 10ms; stages [ 1vu for 100ms ] }
          Setup { sleep(100ms); }
          Actions { sut.api.http.get("/"); }
          Cleanup { sleep(100ms); }
        }
      }
      """

      run(source)
      samples = file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      phases = samples |> Enum.filter(&(&1["target"] == "box")) |> Enum.map(& &1["phase"]) |> Enum.uniq()
      assert "Setup" in phases and "Actions" in phases and "Cleanup" in phases
      assert %{"metric" => "mem", "value" => value} = Enum.find(samples, &(&1["target"] == "box"))
      assert value == 60.0
    end
  end

  describe "MQTT (C161, C163, C164)" do
    defp broker do
      broker = TestBroker.start()
      on_exit(fn -> TestBroker.stop(broker) end)
      broker
    end

    defp mqtt_suite(api, broker, verify, opts \\ []) do
      """
      TestSuite S {
        Config {
          sut {
            api  { baseUrl = "#{api.url}"; }
            plug { metrics = [power]; topics { power = "tele/plug/SENSOR"; } }
          }
          monitoring {
            carbonIntensity = 360gCO2e/kWh;
            mqtt { broker = "#{broker.url}"; #{opts[:fields] || ~s|fields { power = "ENERGY.Power"; }|} }
          }
        }
        Test T {
          Load { thinkTime 10ms; stages [ 1vu for 400ms ] }
          Setup { sleep(50ms); }
          Actions { sut.api.http.get("/"); }
          Verify { #{verify} }
        }
      }
      """
    end

    defp publisher(broker, messages, opts \\ []) do
      spawn(fn ->
        wait_for_subscription(broker)
        Process.sleep(100)

        for message <- messages do
          TestBroker.publish(broker, "tele/plug/SENSOR", message, opts)
          Process.sleep(50)
        end
      end)
    end

    defp wait_for_subscription(broker) do
      unless TestBroker.subscribed?(broker, "tele/plug/SENSOR") do
        Process.sleep(5)
        wait_for_subscription(broker)
      end
    end

    defp tasmota(power),
      do: JSON.encode!(%{"Time" => "2026-10-31T02:50:00", "ENERGY" => %{"Power" => power, "Total" => 12.45}})

    test "a Tasmota message gives power, and energy integrates it" do
      broker = broker()
      api = server(fn _ -> 200 end)
      publisher(broker, Enum.map(1..4, fn _ -> tasmota(100) end))

      result =
        mqtt_suite(api, broker, """
        assert sut.plug.power.mean() == 100W;
        assert power.mean() == 100W;
        assert energy.total() > 30J;
        assert energy.total() < 60J;
        assert carbon.total() > 0gCO2e;
        """)
        |> run()

      assert result.exit_code == 0, inspect(hd(tests(result)).verify)
      assert [%{name: "plug", energy: %{source: "mqtt", samples: samples}}] = hd(tests(result)).targets
      assert samples >= 3
    end

    test "a plain number needs no field" do
      broker = broker()
      api = server(fn _ -> 200 end)
      publisher(broker, ["87.5", "87.5", "87.5"])
      result = run(mqtt_suite(api, broker, "assert sut.plug.power.max() == 87.5W;", fields: ""))
      assert result.exit_code == 0
    end

    test "retained messages are ignored" do
      broker = broker()
      api = server(fn _ -> 200 end)
      publisher(broker, [tasmota(999)], retain: true)
      publisher(broker, [tasmota(100), tasmota(100)])
      result = run(mqtt_suite(api, broker, "assert sut.plug.power.max() == 100W;"))
      assert result.exit_code == 0
    end

    test "no message in the window is a failed assert with no value (C164)" do
      broker = broker()
      api = server(fn _ -> 200 end)
      result = run(mqtt_suite(api, broker, "assert energy.total() < 1J;"))
      assert result.exit_code == 1
      assert [%{energy: %{samples: 0, total: nil}}] = hd(tests(result)).targets
    end

    test "the console report shows a reading with no sample as no value" do
      broker = broker()
      api = server(fn _ -> 200 end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          run(mqtt_suite(api, broker, "assert energy.total() < 1J;"), report: true)
        end)

      assert output =~ "  plug power no value (0 samples)"
      assert output =~ "  plug energy no value (mqtt, 0 samples)"
    end

    test "a broker that cannot be reached ends the run with exit code 2" do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)
      api = server(fn _ -> 200 end)
      result = run(mqtt_suite(api, %{url: "mqtt://127.0.0.1:#{port}"}, "assert true;"))
      assert result.exit_code == 2
      assert result.message =~ "MQTT"
    end
  end

  describe "time limits and exit codes (C132, C155, C171)" do
    test "a Setup over its limit ends the run with exit code 2, and Cleanup still runs" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          setup: "while true { sleep(1ms); }",
          actions: ~S|sut.api.http.get("/actions");|,
          cleanup: ~S|sut.api.http.get("/cleanup");|
        )

      result = run(source, phase_limit_ms: 100)
      assert result.exit_code == 2
      assert [%{path: "/cleanup"}] = TestServer.requests(server)
    end

    test "an interrupt skips Verify, runs Cleanup, and exits with 2" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          load: "thinkTime 10ms; stages [ 2vu for 30s ]",
          actions: ~S|sut.api.http.get("/actions");|,
          verify: ~S|sut.api.http.get("/verify");|,
          cleanup: ~S|sut.api.http.get("/cleanup");|
        )

      runner = self()
      Process.send_after(runner, :perflang_interrupt, 150)
      result = run(source)
      assert result.exit_code == 2
      paths = Enum.map(TestServer.requests(server), & &1.path)
      assert "/cleanup" in paths
      refute "/verify" in paths
      assert hd(tests(result)).result == :aborted
    end

    test "the command line gives the exit codes of C132" do
      server = server(fn _ -> 200 end)
      pass = temp("pass.perf")
      fail = temp("fail.perf")
      broken = temp("broken.perf")
      File.write!(pass, suite(server, actions: ~S|sut.api.http.get("/");|))

      File.write!(
        fail,
        suite(server, actions: ~S|sut.api.http.get("/");|, verify: "assert errors.count() == 1;")
      )

      File.write!(broken, "TestSuite {")

      ExUnit.CaptureIO.capture_io(fn ->
        assert Aetherion.CLI.main(["run", pass, "--seed", "1"]) == 0
        assert Aetherion.CLI.main(["run", fail]) == 1
      end)

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Aetherion.CLI.main(["run", broken]) == 2
        assert Aetherion.CLI.main(["run", "/does/not/exist.perf"]) == 2
        assert Aetherion.CLI.main(["run"]) == 2
      end)
    end

    test "the command line reads an external configuration file" do
      server = server(fn _ -> 200 end)
      suite_file = temp("config.perf")
      config_file = temp("staging.perfcfg")
      File.write!(suite_file, ~S|TestSuite S { Test T { Load { } Actions { sut.ext.http.get("/"); } } }|)
      File.write!(config_file, ~s|Config { sut { ext { baseUrl = "#{server.url}"; } } }|)

      ExUnit.CaptureIO.capture_io(fn ->
        assert Aetherion.CLI.main(["run", suite_file, "--config", config_file]) == 0
      end)

      assert [%{path: "/"}] = TestServer.requests(server)
    end

    test "a console report shows the Test, its metrics and each Verify assert (C131)" do
      server = server(fn _ -> 200 end)
      source = suite(server, actions: ~S|sut.api.http.get("/a");|, verify: "assert errors.rate() < 2%;")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert run(source, report: true, seed: 5).exit_code == 0
        end)

      assert output =~ "Test T: PASSED"
      assert output =~ "GET api/a"
      assert output =~ "passed assert errors.rate() < 2%  (errors.rate() = 0.0%)"
      assert output =~ "Seed 5, passed"
    end
  end

  describe "runs (C178-C180)" do
    test "the whole suite runs count times, in order, each run with its own Tests and files" do
      server = server(fn _ -> 200 end)
      requests = temp("runs.jsonl")
      summary = temp("runs.json")

      source = """
      TestSuite S {
        #{config(server, ~s|runs { count = 3; } output { requests { file = "#{requests}"; fields = [run, test, url]; } summary = "#{summary}"; }|)}
        Test A { Load { stages [ 1vu for 2iter ] } Actions { sut.api.http.get("/a"); } }
        Test B { Load { } Actions { sut.api.http.get("/b"); } }
      }
      """

      result = run(source, seed: 42)
      assert result.exit_code == 0
      assert Enum.map(result.runs, & &1.run) == [1, 2, 3]
      assert Enum.all?(result.runs, &(Enum.map(&1.tests, fn t -> t.name end) == ["A", "B"]))

      # Interleaved: run 1 (A, B), run 2 (A, B), run 3 (A, B).
      paths = Enum.map(TestServer.requests(server), & &1.path)
      assert paths == List.flatten(List.duplicate(["/a", "/a", "/b"], 3))

      lines = requests |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      assert Enum.map(lines, & &1["run"]) == [1, 1, 1, 2, 2, 2, 3, 3, 3]
      assert hd(lines) == %{"run" => 1, "test" => "A", "url" => "/a"}

      assert %{"version" => 4, "experiment" => %{"count" => 3}, "runs" => runs, "tests" => [a, _b]} =
               summary |> File.read!() |> JSON.decode!()

      assert length(runs) == 3
      assert %{"name" => "A", "result" => "passed", "runs" => %{"counted" => 3, "passed" => 3}} = a

      assert %{"n" => 3, "mean" => 2.0, "sd" => +0.0, "cv" => +0.0, "ci95" => %{"low" => 2.0, "high" => 2.0}} =
               a["aggregate"]["metrics"]["requests"]
    end

    test "each run has its own seed, run 1 the seed itself, and the experiment repeats (C179)" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          output: "runs { count = 3; }",
          actions: ~S|sut.api.http.get("/" + range(0, 100000).random().toString());|
        )

      result = run(source, seed: 7)
      assert Enum.map(result.runs, & &1.seed) == [7, Aetherion.run_seed(7, 2), Aetherion.run_seed(7, 3)]
      assert length(Enum.uniq(Enum.map(result.runs, & &1.seed))) == 3

      first = Enum.map(TestServer.requests(server), & &1.path)
      assert length(Enum.uniq(first)) == 3

      run(source, seed: 7)
      assert Enum.drop(Enum.map(TestServer.requests(server), & &1.path), 3) == first

      # A run replays alone with its own seed.
      run(String.replace(source, "count = 3;", "count = 1;"), seed: Aetherion.run_seed(7, 2))
      assert List.last(Enum.map(TestServer.requests(server), & &1.path)) == Enum.at(first, 1)
    end

    test "a Test passes only when it passed in every counted run; discarded runs do not count" do
      calls = :counters.new(1, [])

      server =
        server(fn _ ->
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) in 3..4, do: 500, else: 200
        end)

      # Requests 3 and 4 fail, so run 2 of 3 fails.
      source =
        suite(server,
          output: "runs { count = 3; }",
          load: "stages [ 1vu for 2iter ]",
          actions: ~S|sut.api.http.get("/");|,
          verify: "assert errors.count() == 0;"
        )

      result = run(source)
      assert result.exit_code == 1
      assert [%{result: :failed, counted: 3, passed: 2, failed: 1}] = result.tests
      assert Enum.map(result.runs, &hd(&1.tests).result) == [:passed, :failed, :passed]

      # The same failure in a discarded run does not decide.
      :counters.put(calls, 1, 0)
      source = String.replace(source, "count = 3;", "count = 3; discard = 2;")
      result = run(source)
      assert result.exit_code == 0
      assert Enum.map(result.runs, & &1.discarded) == [true, true, false]
      assert [%{result: :passed, counted: 1}] = result.tests
      assert %{n: 1} = hd(result.tests).aggregate.metrics.requests
    end

    test "the statistics describe the per-run values (C180)" do
      calls = :counters.new(1, [])

      # Run 1 answers 2 requests with 500, run 2 one, run 3 none.
      server =
        server(fn _ ->
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) in [1, 2, 5], do: 500, else: 200
        end)

      source =
        suite(server,
          output: "runs { count = 3; }",
          load: "stages [ 1vu for 4iter ]",
          actions: ~S|sut.api.http.get("/");|
        )

      result = run(source)
      %{errors: %{count: count, rate: rate}} = hd(result.tests).aggregate.metrics
      assert %{n: 3, mean: 1.0, median: 1, min: 0, max: 2} = count
      assert_in_delta count.sd, 1.0, 1.0e-9
      assert_in_delta count.ci95.high - count.mean, 4.3027 / :math.sqrt(3), 1.0e-9
      assert_in_delta rate.mean, 25.0, 1.0e-9
      assert [%{url: "/", requests: %{n: 3, mean: 4.0}}] = hd(result.tests).aggregate.endpoints
    end

    test "cooldown pauses between runs, and an interrupt during it ends the experiment" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          output: "runs { count = 2; cooldown = 300ms; }",
          actions: ~S|sut.api.http.get("/");|
        )

      result = run(source)
      [first, second] = result.runs
      gap = DateTime.diff(second.started_at, first.started_at, :millisecond) - first.duration_ms
      assert gap >= 290

      Process.send_after(self(), :perflang_interrupt, 150)
      result = run(String.replace(source, "300ms", "5s"))
      assert result.exit_code == 2
      assert [%{status: :ok}] = result.runs
      assert result.duration_ms < 2000
    end

    test "--runs replaces count, and must leave a counted run" do
      server = server(fn _ -> 200 end)
      file = temp("runs.perf")

      File.write!(
        file,
        suite(server, output: "runs { count = 5; discard = 1; }", actions: ~S|sut.api.http.get("/");|)
      )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Aetherion.CLI.main(["run", file, "--runs", "2", "--seed", "3"]) == 0
        end)

      assert length(TestServer.requests(server)) == 2
      assert output =~ "Run 1 of 2 (seed 3, discarded): passed"
      assert output =~ "Test T: PASSED, passed in 1 of 1 counted runs"
      assert output =~ "Seed 3, 2 of 2 runs (1 discarded), passed"

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Aetherion.CLI.main(["run", file, "--runs", "1"]) == 2
        end)

      assert stderr =~ "1 runs with discard 1 leave no counted run"
      assert length(TestServer.requests(server)) == 2
    end

    test "the console shows each run, then each Test across the runs with its interval" do
      server = server(fn _ -> 200 end)

      source =
        suite(server,
          output: "runs { count = 3; }",
          load: "stages [ 1vu for 2iter ]",
          actions: ~S|sut.api.http.get("/a");|,
          verify: "assert errors.rate() < 2%;"
        )

      output = ExUnit.CaptureIO.capture_io(fn -> assert run(source, report: true, seed: 5).exit_code == 0 end)
      assert output =~ "Run 3 of 3 (seed #{Aetherion.run_seed(5, 3)}): passed"
      assert output =~ "  Test T: PASSED, 2 requests"
      assert output =~ "Test T: PASSED, passed in 3 of 3 counted runs"
      assert output =~ "  requests 2.00 ± 0.00 (n=3, CV 0.00%)"
      assert output =~ ~r/latency p95 \d+\.\d\dms ± \d+\.\d\dms \(n=3, CV/
      assert output =~ ~r"GET api/a p95"
      assert output =~ "Seed 5, 3 of 3 runs, passed"
    end
  end

  describe "statistics (C180)" do
    alias Aetherion.Stats

    test "describe gives n, mean, sample sd, cv, median, min, max and a t interval" do
      d = Stats.describe([2, 4, 4, 4, 5, 5, 7, 9])
      assert %{n: 8, mean: 5.0, median: 4.5, min: 2, max: 9} = d
      assert_in_delta d.sd, :math.sqrt(32 / 7), 1.0e-12
      assert_in_delta d.cv, :math.sqrt(32 / 7) / 5 * 100, 1.0e-9
      assert_in_delta d.ci95.low, 5 - 2.3646 * :math.sqrt(32 / 7) / :math.sqrt(8), 1.0e-9

      assert %{n: 1, mean: 3.0, sd: nil, cv: nil, ci95: nil} = Stats.describe([3])
      assert %{cv: nil} = Stats.describe([-1, 1])
      assert Stats.describe([]) == nil
    end

    test "t beyond the table follows its expansion" do
      assert Stats.t975(30) == 2.0423
      assert_in_delta Stats.t975(31), 2.0395, 1.0e-4
      assert_in_delta Stats.t975(60), 2.0003, 1.0e-4
      assert_in_delta Stats.t975(1000), 1.9623, 1.0e-4
    end

    test "merge keeps the shape, skips text and sample counts, and counts only runs with a value" do
      runs = [
        %{latency: %{p95: 10}, source: "agent", readings: %{"cpu" => %{mean: 40, samples: 5}}},
        %{latency: nil, source: "agent", readings: %{"cpu" => %{mean: 60, samples: 5}}},
        %{latency: %{p95: 20}, source: "agent", readings: %{"cpu" => %{mean: 50, samples: 4}}}
      ]

      assert %{latency: %{p95: %{n: 2, mean: 15.0}}, readings: %{"cpu" => %{mean: %{n: 3, mean: 50.0}}}} =
               merged = Stats.merge(runs)

      refute Map.has_key?(merged, :source)
      refute Map.has_key?(merged.readings["cpu"], :samples)
    end
  end
end
