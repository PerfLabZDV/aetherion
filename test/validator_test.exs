defmodule PerfLang.ValidatorTest do
  use ExUnit.Case, async: true

  import PerfLang.TestHelpers
  alias PerfLang.{AST, Error, Validator}

  # Parses, validates, and returns the formatted errors ([] when valid).
  defp errors(source) do
    case source |> PerfLang.parse!() |> Validator.validate() do
      {:ok, _} -> []
      {:error, errors} -> Enum.map(errors, &Error.format/1)
    end
  end

  # warmup and distribution need stages (C124), so a Load without them gets
  # one at the end, after everything the tests check.
  defp load_errors(load) do
    load = if load =~ "stages", do: load, else: load <> " stages [ 1vu for 1iter ]"
    errors(suite("", load))
  end

  defp statement_errors(statements), do: errors(suite(statements))

  test "the full example suite is valid and returned unchanged" do
    {:ok, ast} = PerfLang.parse_file("test/fixtures/full_suite.perf")
    assert Validator.validate(ast) == {:ok, ast}
    assert PerfLang.validate(ast) == {:ok, ast}
  end

  test "collects every error, sorted by position, as validator errors" do
    source = """
    TestSuite S {
      Load {
        warmup 1m90s;
        warmup 2s;
        distribution { a 50%; } stages [ 1vu for 1iter ]
      }
      Test T {
        Actions { x + 1; return 1; }
        Verify { }
      }
    }
    """

    assert {:error, errs} = source |> PerfLang.parse!() |> Validator.validate()
    assert Enum.all?(errs, &(&1.stage == :validator))

    assert Enum.map(errs, &Error.format/1) == [
             "3:12: 1m90s: seconds must be below 60 after the first part (C31, C80)",
             "4:5: duplicate Load setting warmup (first at 3:5); only stopIf may repeat (C78)",
             "5:5: distribution adds up to 50%, must be exactly 100% (C36)",
             "8:15: a bare expression must be a call; keep its value with let or remove it (C63)",
             "8:22: return is only allowed inside a function (C74)"
           ]
  end

  describe "Load placement (C10, C11)" do
    # The grammar enforces both, so these trees are built by hand.
    defp test_node(name, load),
      do: %AST.Test{loc: {5, 3}, name: name, load: load, actions: %AST.Phase{}, verify: %AST.Phase{}}

    test "suite Load and a Test Load" do
      ast = %AST.TestSuite{
        loc: {1, 1},
        name: "S",
        load: %AST.Load{loc: {2, 3}},
        tests: [test_node("A", nil), test_node("B", %AST.Load{loc: {6, 5}})]
      }

      assert {:error, [e]} = Validator.validate(ast)
      assert Error.format(e) == "6:5: Test B defines its own Load, but the suite already defines one (C11)"
    end

    test "no suite Load and a Test without Load" do
      ast = %AST.TestSuite{
        loc: {1, 1},
        name: "S",
        tests: [test_node("A", %AST.Load{loc: {6, 5}}), test_node("B", nil)]
      }

      assert {:error, [e]} = Validator.validate(ast)
      assert e.message == "Test B has no Load; without a suite-level Load every Test must define one (C10)"
    end

    test "Load in every Test is valid" do
      assert errors("""
             TestSuite S {
               Test A { Load { warmup 1s; stages [ 1vu for 1iter ] } Actions { } Verify { } }
               Test B { Load { warmup 1s; stages [ 1vu for 1iter ] } Actions { } Verify { } }
             }
             """) == []
    end

    test "Load settings are checked in Test-level Load too" do
      assert [_] =
               errors("""
               TestSuite S {
                 Test A { Load { warmup 1s; warmup 2s; stages [ 1vu for 1iter ] } Actions { } Verify { } }
               }
               """)
    end
  end

  describe "Load without stages (C124)" do
    test "is valid: it runs one iteration with one virtual user" do
      assert errors(suite("")) == []
      assert errors(suite("", "requestTimeout 5s; thinkTime 1s; curves { } retry { attempts 2; }")) == []
    end

    test "warmup is shorter than the stages (C167)" do
      assert errors(suite("", "warmup 2m; stages [ 50vu for 5m ]")) == []
      assert errors(suite("", "warmup 59s; stages [ 10vu now, 50vu in 30s, 50vu for 30s ]")) == []

      assert [m1] = errors(suite("", "warmup 5m; stages [ 50vu for 5m ]"))
      assert m1 =~ "warmup 5m must be shorter than the stages (C167)"

      assert [m2] = errors(suite("", "warmup 1m1s; stages [ 1vu in 30s, 1vu for 30s ]"))
      assert m2 =~ "warmup 1m1s must be shorter"
    end

    test "with an iteration count the length is only known at run time (C167)" do
      assert errors(suite("", "warmup 1h; stages [ 50vu for 1s, 50vu for 10iter ]")) == []
    end

    test "warmup and distribution need stages" do
      assert errors(suite("", "warmup 1m; distribution { a 100%; }")) == [
               "2:10: warmup needs stages; without stages the single iteration falls inside the warmup " <>
                 "and no metric is recorded (C124)",
               "2:21: distribution needs stages; without stages one virtual user runs one iteration, " <>
                 "so there is nothing to distribute (C124)"
             ]

      assert errors(suite("", "warmup 1m; distribution { a 100%; } stages [ 1vu for 1iter ]")) == []
    end

    test "also in a Test-level Load" do
      assert [message] =
               errors("TestSuite S { Test T { Load { warmup 1m; } Actions { } } }")

      assert message =~ "1:31: warmup needs stages"
    end
  end

  describe "Load settings at most once (C61, C78)" do
    test "every setting may appear once, in any order" do
      assert load_errors("""
             retry { } distribution { a 100%; } thinkTime 1s; stages [ 1vu for 2s ]
             curves { } requestTimeout 5s; warmup 1s;
             """) == []
    end

    test "each repeated setting is reported at the repeat" do
      for setting <- [
            "warmup 1s;",
            "thinkTime 1s;",
            "requestTimeout 5s;",
            "curves { }",
            "stages [ 1vu for 1s ]",
            "distribution { a 100%; }",
            "retry { }"
          ] do
        name = setting |> String.split() |> hd()
        assert [message] = load_errors("#{setting} #{setting}")
        assert message =~ "duplicate Load setting #{name} (first at 2:10)"
      end
    end

    test "a third occurrence is reported too" do
      assert [_, _] = load_errors("warmup 1s; warmup 2s; warmup 3s;")
    end

    test "stopIf may repeat" do
      assert load_errors("stopIf errors.rate() > 5%; stopIf latency.p95() > 2s;") == []
    end
  end

  describe "Config (C98-C100, C119-C122)" do
    defp config_errors(config),
      do: errors("TestSuite S { #{config} Load { } Test T { Actions { } Verify { } } }")

    defp base_url_errors(url), do: config_errors(~s(Config { sut { a { baseUrl = "#{url}"; } } }))

    test "a full Config is valid" do
      assert config_errors("""
             Config {
               sut {
                 euCentral { baseUrl = "https://eu.api.examp.com"; }
                 usEast    { baseUrl = "http://192.168.178.71:8080/api"; }
               }
             }
             """) == []
    end

    test "sut at most once" do
      assert config_errors("Config { sut { } sut { } }") ==
               ["1:32: duplicate Config section sut (first at 1:24) (C98)"]
    end

    test "each target at most once" do
      assert config_errors("Config { sut { a { } b { } a { } } }") ==
               ["1:42: duplicate sut target a (first at 1:30) (C100)"]
    end

    test "no target named cpu, since sut.cpu means all targets (C109)" do
      assert [message] = config_errors("Config { sut { cpu { } } }")
      assert message =~ "1:30: a sut target cannot be named cpu"
    end

    defp requests_errors(settings), do: config_errors("Config { output { requests { #{settings} } } }")

    test "output: valid files" do
      assert config_errors("""
             Config {
               output {
                 requests { file = "results/requests.jsonl"; fields = [status, latency]; includeWarmup = false; }
                 summary = "summary.json";
               }
             }
             """) == []

      assert requests_errors(~s(file = "r.jsonl";)) == []
    end

    test "output at most once, each setting at most once (C98, C119)" do
      assert [m1] = config_errors("Config { output { } output { } }")
      assert m1 =~ "duplicate Config section output (first at 1:24) (C98)"

      assert [m2] = config_errors(~s(Config { output { summary = "a.json"; summary = "b.json"; } }))
      assert m2 =~ "duplicate summary in output (first at 1:33) (C119)"
    end

    test "output file extensions (C120, C121)" do
      for path <- ["r.csv", "r.json", "r.txt", "r", ".jsonl", "r.JSONL", ""] do
        assert [message] = requests_errors(~s(file = "#{path}";)), path
        assert message =~ "requests file #{inspect(path)} must end in .jsonl (C120)"
      end

      for path <- ["s.jsonl", "s.csv", "s", ".json"] do
        assert [message] = config_errors(~s(Config { output { summary = "#{path}"; } })), path
        assert message =~ "summary file #{inspect(path)} must end in .json (C121)"
      end
    end

    test "requests needs a file; each setting at most once (C122)" do
      assert [m1] = requests_errors("fields = [status];")
      assert m1 =~ "1:33: requests needs a file"

      assert [m2] = requests_errors(~s(file = "a.jsonl"; includeWarmup = true; includeWarmup = false;))
      assert m2 =~ "duplicate includeWarmup in requests (first at 1:62) (C122)"
    end

    test "fields: known names, at least one, each once; warmup is not a field (C122)" do
      all =
        "time, run, test, phase, virtualUser, iteration, target, method, url, status, latency, outcome, attempt"

      assert requests_errors(~s(file = "r.jsonl"; fields = [#{all}];)) == []

      assert [m1] = requests_errors(~s(file = "r.jsonl"; fields = [];))
      assert m1 =~ "fields needs at least one field; leave it out to write all fields (C122)"

      assert [m2, m3, m4] = requests_errors(~s(file = "r.jsonl"; fields = [statu, status, status, warmup];))
      assert m2 =~ "unknown field statu; use time, run, test, phase, virtualUser"
      assert m3 =~ "duplicate field status"
      assert m4 =~ "warmup is not a field; includeWarmup = true; writes warmup requests with it (C122)"
    end

    test "baseUrl at most once per target" do
      assert [message] =
               config_errors(~s(Config { sut { a { baseUrl = "http://x"; baseUrl = "http://y"; } } }))

      assert message =~ "duplicate baseUrl in sut target a (first at 1:34) (C99)"
    end

    test "baseUrl is an http:// or https:// URL with a host" do
      for url <- ["https://eu.api.examp.com", "http://192.168.178.71:8080", "https://x.com/api/v1"] do
        assert base_url_errors(url) == []
      end

      for url <- ["", "eu.api.examp.com", "ftp://x.com", "https://", "http:///x", "https://x .com"] do
        assert [message] = base_url_errors(url)
        assert message =~ "baseUrl #{inspect(url)} must be an http:// or https:// URL with a host (C99)"
      end
    end

    test "host is a host name or address, once per target (C156)" do
      for host <- ["10.0.0.20", "db.internal", "localhost", "2001:db8::1"] do
        assert config_errors(~s(Config { sut { a { host = "#{host}"; } } })) == []
      end

      for host <- ["", "http://db", "db/path", "a b"] do
        assert [message] = config_errors(~s(Config { sut { a { host = "#{host}"; } } }))

        assert message =~
                 "host #{inspect(host)} must be a host name or address, without scheme or path (C156)"
      end

      assert [message] = config_errors(~s(Config { sut { a { host = "x"; host = "y"; } } }))
      assert message =~ "duplicate host in sut target a"
    end

    test "metrics: known names, at least one, each once, on a machine (C159)" do
      assert config_errors(~s(Config { sut { a { host = "h"; metrics = [cpu, mem, disk, gpu, power]; } } })) ==
               []

      assert config_errors(~s(Config { sut { a { baseUrl = "http://a"; metrics = [cpu]; } } })) == []

      assert [m1] = config_errors(~s(Config { sut { a { host = "h"; metrics = [ram]; } } }))
      assert m1 =~ "unknown metric ram; use cpu, mem, disk, net, gpu, power (C159)"

      assert [m2] = config_errors(~s(Config { sut { a { host = "h"; metrics = []; } } }))
      assert m2 =~ "metrics needs at least one metric"

      assert [m3] = config_errors(~s(Config { sut { a { host = "h"; metrics = [cpu, cpu]; } } }))
      assert m3 =~ "duplicate metric cpu"

      assert [m4] = config_errors(~s(Config { sut { a { metrics = [cpu]; } } }))
      assert m4 =~ "target a lists metrics from an agent, so it needs a host or a baseUrl (C159)"
    end

    test "selectors fit their metric (C159)" do
      source = ~s(Config { sut { a { host = "h"; metrics = [cpu[0, 1], gpu[2], disk["sda", "sdb"]]; } } })
      assert config_errors(source) == []

      assert [m1] = config_errors(~s(Config { sut { a { host = "h"; metrics = [mem[0]]; } } }))
      assert m1 =~ "mem takes no device selector (C159)"

      assert [m2] = config_errors(~s(Config { sut { a { host = "h"; metrics = [power[0]]; } } }))
      assert m2 =~ "power takes no device selector"

      assert [m3] = config_errors(~s(Config { sut { a { host = "h"; metrics = [disk[1]]; } } }))
      assert m3 =~ ~s|disk selects devices by name, e.g. disk["nvme0n1"], not 1 (C159)|

      assert [m4] = config_errors(~s(Config { sut { a { host = "h"; metrics = [cpu["a"]]; } } }))
      assert m4 =~ ~s|cpu selects devices by number, not "a" (C159)|
    end

    test "net is a metric, selected by interface name (C186)" do
      assert config_errors(~s(Config { sut { a { host = "h"; metrics = [net, cpu]; } } })) == []
      assert config_errors(~s(Config { sut { a { host = "h"; metrics = [net["eth0", "eth1"]]; } } })) == []

      assert [m1] = config_errors(~s(Config { sut { a { host = "h"; metrics = [net[0]]; } } }))
      assert m1 =~ ~s|net selects devices by name, e.g. net["eth0"], not 0 (C186)|

      assert [m2] = config_errors(~s(Config { sut { net { host = "h"; } } }))
      assert m2 =~ "a sut target cannot be named net"
    end

    test "aetherion is a format (C185)" do
      assert config_errors(~s(Config { monitoring { format = aetherion; } })) == []
    end

    test "metricsPort needs metrics, and fits a port (C158, C159)" do
      assert config_errors(~s(Config { sut { a { host = "h"; metrics = [gpu]; metricsPort = 9400; } } })) ==
               []

      assert [m1] = config_errors(~s(Config { sut { a { host = "h"; metricsPort = 9400; } } }))
      assert m1 =~ "metricsPort needs metrics in target a (C159)"

      assert [m2] =
               config_errors(~s(Config { sut { a { host = "h"; metrics = [gpu]; metricsPort = 70000; } } }))

      assert m2 =~ "metricsPort 70000 must be from 1 to 65535 (C158)"
    end

    test "a target is not named after a machine metric (C109)" do
      for name <- ~w(cpu mem disk gpu) do
        assert [message] = config_errors(~s(Config { sut { #{name} { } } }))
        assert message =~ "a sut target cannot be named #{name}; sut.#{name} reads all targets (C109)"
      end
    end

    defp mqtt_errors(settings), do: config_errors("Config { monitoring { mqtt { #{settings} } } }")

    test "mqtt needs an mqtt:// broker (C163)" do
      assert mqtt_errors(~s(broker = "mqtt://b:1883";)) == []
      assert mqtt_errors(~s(broker = "mqtt://broker.examp.com";)) == []

      assert [m1] = mqtt_errors("")
      assert m1 =~ "mqtt needs a broker"

      for url <- ["http://b", "mqtts://b:8883", "mqtt://", "b:1883"] do
        assert [message] = mqtt_errors(~s(broker = "#{url}";))
        assert message =~ "broker #{inspect(url)} must be an mqtt:// URL with a host (C163)"
      end
    end

    test "qos and settings at most once (C163)" do
      broker = ~s(broker = "mqtt://b";)
      for qos <- 0..2, do: assert(mqtt_errors("#{broker} qos = #{qos};") == [])

      assert [m1] = mqtt_errors("#{broker} qos = 3;")
      assert m1 =~ "qos 3 must be 0, 1 or 2 (C163)"

      assert [m2] = mqtt_errors("#{broker} #{broker}")
      assert m2 =~ "duplicate broker in mqtt"

      assert [m3] = config_errors("Config { monitoring { mqtt { #{broker} } mqtt { #{broker} } } }")
      assert m3 =~ "duplicate mqtt in monitoring"
    end

    test "fields map known metrics to dotted paths (C163)" do
      broker = ~s(broker = "mqtt://b";)
      assert mqtt_errors(~s(#{broker} fields { power = "ENERGY.Power"; mem = "m"; })) == []

      assert [m1] = mqtt_errors(~s(#{broker} fields { watts = "a"; }))
      assert m1 =~ "unknown metric watts"

      assert [m2] = mqtt_errors(~s(#{broker} fields { power = "a"; power = "b"; }))
      assert m2 =~ "duplicate field for power"

      for path <- ["", ".a", "a.", "a..b", "a b"] do
        assert [message] = mqtt_errors(~s(#{broker} fields { power = "#{path}"; }))
        assert message =~ "must be a metric name or a dotted JSON path"
      end
    end

    test "topics name listed metrics, once, without wildcards (C163)" do
      assert config_errors(~s(Config { sut { a { metrics = [power]; topics { power = "t/p"; } } } })) == []

      assert [m1] =
               config_errors(
                 ~s(Config { sut { a { host = "h"; metrics = [cpu]; topics { power = "t"; } } } })
               )

      assert m1 =~ "topic for power needs power in the metrics of target a (C163)"

      assert [m2] =
               config_errors(
                 ~s(Config { sut { a { metrics = [power]; topics { power = "t"; power = "u"; } } } })
               )

      assert m2 =~ "duplicate topic for power"

      assert [m3] =
               config_errors(~s(Config { sut { a { host = "h"; metrics = [cpu]; topics { ram = "t"; } } } }))

      assert m3 =~ "unknown metric ram"

      for topic <- ["", "tele/+/SENSOR", "tele/#"] do
        assert [message] =
                 config_errors(~s(Config { sut { a { metrics = [power]; topics { power = "#{topic}"; } } } }))

        assert message =~ "must name one topic, without wildcards (C163)"
      end
    end

    test "only metrics from an agent need a host (C159, C163)" do
      assert [message] =
               config_errors(~s(Config { sut { a { metrics = [cpu, power]; topics { power = "t"; } } } }))

      assert message =~ "target a lists metrics from an agent"
    end

    test "fields in monitoring, each once, for known metrics (C158)" do
      assert config_errors(~s|Config { monitoring { fields { gpu = "DCGM_FI_DEV_GPU_UTIL"; } } }|) == []

      assert [m1] = config_errors(~s|Config { monitoring { fields { gpu = "a"; gpu = "b"; } } }|)
      assert m1 =~ "duplicate field for gpu"

      assert [m2] = config_errors(~s|Config { monitoring { fields { ram = "a"; } } }|)
      assert m2 =~ "unknown metric ram"
    end

    test "samples in output ends in .jsonl, at most once (C173)" do
      assert config_errors(~s|Config { output { samples { file = "s.jsonl"; } } }|) == []

      assert [m1] = config_errors(~s|Config { output { samples { file = "s.json"; } } }|)
      assert m1 =~ ~s|samples file "s.json" must end in .jsonl (C173)|

      assert [m2] =
               config_errors(
                 ~s|Config { output { samples { file = "a.jsonl"; } samples { file = "b.jsonl"; } } }|
               )

      assert m2 =~ "duplicate samples in output"
    end

    test "any is not a target name (C168)" do
      assert [message] = config_errors("Config { sut { any { } } }")
      assert message =~ "a sut target cannot be named any; sut.any picks a target by distribution (C168)"
    end

    test "monitoring settings (C158, C161)" do
      source =
        ~s(Config { monitoring { interval = 1s; port = 9100; path = "/metrics"; format = json; carbonIntensity = 380gCO2e/kWh; } })

      assert config_errors(source) == []

      for {settings, expected} <- [
            {"interval = 0s;", "interval 0s must be greater than 0 (C158)"},
            {"port = 0;", "port 0 must be from 1 to 65535 (C158)"},
            {"port = 70000;", "port 70000 must be from 1 to 65535"},
            {~s(path = "metrics";), ~s|path "metrics" must start with "/" (C158)|},
            {"format = xml;", "unknown format xml; use prometheus, json or aetherion (C158, C185)"},
            {"carbonIntensity = 0gCO2e/kWh;", "carbonIntensity 0gCO2e/kWh must be greater than 0 (C161)"},
            {"port = 1; port = 2;", "duplicate port in monitoring"}
          ] do
        assert [message] = config_errors("Config { monitoring { #{settings} } }")
        assert message =~ expected
      end

      assert [message] = config_errors("Config { monitoring { } monitoring { } }")
      assert message =~ "duplicate Config section monitoring"
    end

    test "an external configuration file gets the Config checks, and holds only sut and monitoring (C157)" do
      {:ok, config} = PerfLang.parse_config(~s(Config { sut { a { baseUrl = "http://a"; } } }))
      assert {:ok, ^config} = Validator.validate(config)

      {:ok, config} = PerfLang.parse_config(~s(Config { sut { a { baseUrl = "ftp://a"; } } output { } }))
      assert {:error, [%Error{stage: :validator} = first, second]} = Validator.validate(config)
      assert first.message =~ "must be an http:// or https:// URL"

      assert second.message ==
               "an external configuration file holds only the sut, monitoring and workers sections (C157, C178, C181)"

      {:ok, config} = PerfLang.parse_config(~s(Config { runs { count = 3; } }))
      assert {:error, [%Error{message: message}]} = Validator.validate(config)
      assert message =~ "holds only the sut, monitoring and workers sections"

      {:ok, config} = PerfLang.parse_config(~s(Config { workers { w1 { host = "10.0.0.11"; } } }))
      assert {:ok, _config} = Validator.validate(config)
    end

    test "workers: each name once, not a metric, and exactly one host without @ (C181, C183)" do
      assert config_errors(
               ~s|Config { workers { euWorker1 { host = "10.0.0.11"; } w2 { host = "w2.example"; } } }|
             ) ==
               []

      assert config_errors("Config { workers { } }") == []

      assert [message] =
               config_errors(~s|Config { workers { w1 { host = "10.0.0.11"; } w1 { host = "10.0.0.12"; } } }|)

      assert message =~ "duplicate worker w1 (first at 1:34) (C181)"

      assert [message] = config_errors(~s|Config { workers { mem { host = "10.0.0.11"; } } }|)
      assert message =~ "a worker cannot be named mem; loadGenerator.mem reads all workers (C183)"

      assert [message] = config_errors("Config { workers { w1 { } } }")
      assert message =~ "worker w1 needs a host"

      assert [message] = config_errors(~s|Config { workers { w1 { host = "a"; host = "b"; } } }|)
      assert message =~ "duplicate host in worker w1 (C181)"

      assert [message] = config_errors(~s|Config { workers { w1 { host = "me@10.0.0.11"; } } }|)
      assert message =~ "cannot hold @; its node is w1@<host> (C181)"

      assert [message] = config_errors(~s|Config { workers { w1 { host = "http://10.0.0.11"; } } }|)
      assert message =~ "without scheme or path (C156)"

      assert [message] = config_errors(~s|Config { workers { } workers { } }|)
      assert message =~ "duplicate Config section workers"
    end

    test "runs: each setting once, count at least 1, discard below count (C178)" do
      assert config_errors("Config { runs { count = 10; cooldown = 30s; discard = 1; } }") == []
      assert config_errors("Config { runs { } }") == []

      assert [message] = config_errors("Config { runs { count = 2; count = 3; } }")
      assert message =~ "duplicate count in runs (first at 1:31) (C178)"

      assert [message] = config_errors("Config { runs { count = 0; } }")
      assert message =~ "count 0 runs nothing; it must be at least 1 (C178)"

      assert [message] = config_errors("Config { runs { count = 3; discard = 3; } }")
      assert message =~ "discard 3 leaves no counted run; it must be below count 3 (C178)"

      # Without count there is one run, so any discard leaves none.
      assert [_] = config_errors("Config { runs { discard = 1; } }")

      assert [message] = config_errors("Config { runs { } runs { } }")
      assert message =~ "duplicate Config section runs"
    end

    test "baseUrl has no trailing slash, reported at the string" do
      assert base_url_errors("https://x.com/") ==
               [~s[1:44: baseUrl "https://x.com/" must not end with "/" (C99)]]

      assert [_] = base_url_errors("https://x.com/api/")
    end
  end

  describe "iteration counts greater than 0 (C102)" do
    test "positive counts are valid, in ramp and hold stages" do
      assert load_errors("stages [ 1vu for 10iter, 5vu in 1iter, 0vu in 30s ]") == []
    end

    test "0iter is rejected at the count" do
      assert load_errors("stages [ 1vu for 0iter, 5vu in 0iter exp ]") == [
               "2:27: iteration count 0iter must be greater than 0 (C102)",
               "2:41: iteration count 0iter must be greater than 0 (C102)"
             ]
    end

    test "0iter/vu is rejected too" do
      assert load_errors("stages [ 1vu for 0iter/vu ]") == [
               "2:27: iteration count 0iter/vu must be greater than 0 (C102)"
             ]
    end
  end

  describe "iteration counts per user (C175)" do
    test "are valid in hold stages, mixed with the other lengths" do
      assert load_errors("stages [ 20vu for 1iter/vu, 10vu in 1m, 10vu for 3iter/vu, 10vu for 5iter ]") == []
    end

    test "are rejected in a ramp, at the count" do
      assert load_errors("stages [ 10vu for 1m, 50vu in 2iter/vu exp ]") == [
               "2:40: 50vu in 2iter/vu: a count per user only works in a for stage; " <>
                 "a ramp takes a total such as 2iter (C175)"
             ]
    end
  end

  describe "now stages (C127)" do
    test "a now stage anywhere but last is valid" do
      assert load_errors("stages [ 10vu now, 100vu in 2m, 500vu now, 500vu for 1m ]") == []
    end

    test "a now stage as the last stage is rejected at the stage" do
      assert load_errors("stages [ 50vu for 1m, 0vu now ]") == [
               "2:32: 0vu now is the last stage; the run ends there, so it never takes effect (C127)"
             ]

      assert [message] = load_errors("stages [ 10vu now ]")
      assert message =~ "10vu now is the last stage"
    end
  end

  describe "requestTimeout greater than 0 (C96)" do
    test "any positive Time is valid" do
      for value <- ["5s", "1ms", "0.5s", "0m1s", "1h"] do
        assert load_errors("requestTimeout #{value};") == []
      end
    end

    test "zero is rejected at the value, in every spelling" do
      assert load_errors("requestTimeout 0s;") == ["2:25: requestTimeout 0s must be greater than 0 (C96)"]

      for value <- ["0ms", "0.0s", "0m0s", "0h0m0s0ms"] do
        assert [message] = load_errors("requestTimeout #{value};")
        assert message =~ "requestTimeout #{value} must be greater than 0"
      end
    end
  end

  describe "retry entries at most once (C85)" do
    test "each entry once is valid" do
      assert load_errors("retry { backoff fixed; delay 1s; attempts 3; }") == []
    end

    test "repeats are reported" do
      assert [a, d, b] =
               load_errors(
                 "retry { attempts 1; delay 1s; backoff fixed; attempts 2; delay 2s; backoff linear; }"
               )

      assert a =~ "duplicate retry entry attempts"
      assert d =~ "duplicate retry entry delay"
      assert b =~ "duplicate retry entry backoff"
    end
  end

  describe "distribution (C36, C87)" do
    test "exactly 100% in hundredths" do
      assert load_errors("distribution { a 33.33%; b 33.33%; c 33.34%; }") == []
      assert load_errors("distribution { a 100%; }") == []
      assert load_errors("distribution { a 99.5%; b 0.5%; }") == []
      assert load_errors("distribution { a 100%; b 0%; }") == []
    end

    test "below or above 100% is an error, with no rounding slack" do
      assert ["2:10: distribution adds up to 99.99%, must be exactly 100% (C36)"] =
               load_errors("distribution { a 33.33%; b 33.33%; c 33.33%; }")

      assert ["2:10: distribution adds up to 100.01%, must be exactly 100% (C36)"] =
               load_errors("distribution { a 50%; b 50.01%; }")

      assert ["2:10: distribution adds up to 100.1%, must be exactly 100% (C36)"] =
               load_errors("distribution { a 50%; b 50.1%; }")
    end

    test "each target once" do
      assert ["2:32: duplicate distribution target a (first at 2:25) (C87)"] =
               load_errors("distribution { a 50%; a 50%; }")
    end

    test "each value at most 100%" do
      assert [total, value] = load_errors("distribution { a 150%; b 0%; }")
      assert value == "2:27: distribution value 150% for a is above 100% (C87)"
      assert total =~ "adds up to 150%"
    end
  end

  describe "sleep (C133)" do
    test "takes a Time, or a value left to the Semantic Analyzer" do
      assert statement_errors("sleep(2s); sleep(0s); sleep(1m30s); sleep(pause); sleep(pause * 2);") == []
    end

    test "works in every phase and in functions" do
      source = """
      TestSuite S {
        Functions {
          fn pause(): Unit { sleep(1s); }
        }
        Load { }
        Test T {
          Setup { sleep(1s); }
          Actions { sleep(1s); }
          Verify { sleep(1s); }
          Cleanup { sleep(1s); }
        }
      }
      """

      assert errors(source) == []
    end

    test "takes exactly one argument" do
      assert [m1, m2] = statement_errors("sleep(); sleep(1s, 2s);")
      assert m1 =~ "sleep takes one Time, got 0 arguments (C133)"
      assert m2 =~ "sleep takes one Time, got 2 arguments (C133)"
    end

    test "a literal must be a Time" do
      for arg <- ["5", ~s("2s"), "50%", "10J", "true"] do
        assert [message] = statement_errors("sleep(#{arg});"), arg
        assert message =~ "sleep takes a Time such as 2s (C133)"
      end
    end

    test "must not be negative" do
      assert [message] = statement_errors("sleep(-2s);")
      assert message =~ "sleep(-2s) must not be negative (C133)"
      assert statement_errors("sleep(!pause);") == []
    end

    test "the Time literal is still checked" do
      assert [message] = statement_errors("sleep(7m90s);")
      assert message =~ "7m90s: seconds must be below 60 after the first part (C31, C80)"
    end

    test "a function cannot be named sleep" do
      source = """
      TestSuite S {
        Functions {
          fn sleep(t: Time): Unit { }
        }
        Load { }
        Test T { Actions { } }
      }
      """

      assert ["3:5: a function cannot be named sleep; it is a built-in (C133)"] = errors(source)
    end
  end

  describe "random (C134)" do
    test "takes no argument or a count, on lists and JSON arrays" do
      assert statement_errors(~s|let a = regions.random(); let b = r.body["products"].random()["id"];|) == []
      assert statement_errors("let picks = items.random(5); let more = items.random(count);") == []
    end

    test "more than one argument is an error" do
      assert [m1, m2] = statement_errors("items.random(0, 10); items.random(1, 2, 3);")
      assert m1 =~ "random takes at most one count, got 2 arguments (C134)"
      assert m2 =~ "random takes at most one count, got 3 arguments (C134)"
    end

    test "random stays usable as a name" do
      assert statement_errors("let random = 1; random(2, 3);") == []
    end

    test "http.random is an unknown http method, not this method" do
      assert [message] = statement_errors("sut.a.http.random();")
      assert message =~ "unknown http method random"
    end
  end

  describe "Time literals (C31, C80, C81)" do
    test "first part is not capped; later parts are" do
      assert load_errors("warmup 90s; thinkTime 1500ms;") == []
      assert load_errors("warmup 100h59m59s999ms;") == []
      assert load_errors("warmup 1m59.99s;") == []
    end

    test "parts after the first must be in range" do
      assert ["2:17: 7m90s: seconds must be below 60 after the first part (C31, C80)"] =
               load_errors("warmup 7m90s;")

      assert [m] = load_errors("warmup 1h60m;")
      assert m =~ "1h60m: minutes must be below 60"
      assert [ms] = load_errors("warmup 2s1000ms;")
      assert ms =~ "2s1000ms: milliseconds must be below 1000"
      assert [_, _] = load_errors("warmup 1h75m75s;")
    end

    test "only the last part may have decimals" do
      assert load_errors("warmup 1m30.5s;") == []

      assert ["2:17: 1.5m30s: only the last part may have decimals, not 1.5m (C81)"] =
               load_errors("warmup 1.5m30s;")
    end

    test "Time literals are checked everywhere, not only in Load" do
      assert [stage] = load_errors("stages [ 10vu in 1m60s ]")
      assert stage =~ "1m60s"
      assert [stmt] = statement_errors("let x = [1s, 2m70s];")
      assert stmt =~ "2m70s"
      assert [stop] = load_errors("stopIf latency.p95() > 1.5s500ms;")
      assert stop =~ "only the last part may have decimals"
    end
  end

  describe "http calls (C112-C115)" do
    test "every method, with and without a target, is valid" do
      assert statement_errors("""
             http.get("http://192.168.178.71:8080/api/health");
             http.head("https://x.io", { "headers": { "A": "b" } });
             sut.a.http.delete("/items/1");
             region.http.post("/cart", { "id": 1 }, { "headers": { "A": "b" }, "query": { "p": 2 } });
             sut.a.http.put("/cart", "", { "query": {} });
             sut.a.http.patch("/cart", body);
             let r = http.get(url, options).status;
             """) == []
    end

    test "unknown method" do
      assert [message] = statement_errors(~s[sut.a.http.fetch("/x");])
      assert message =~ "unknown http method fetch; use get, head, delete, post, put or patch (C112)"
    end

    test "http on its own, or without a call" do
      for expr <- ["let r = http;", "let g = http.get;", "f(http);"] do
        assert [message] = statement_errors(expr), expr
        assert message =~ "http can only be called as http.<method>(...)"
      end
    end

    test "number of arguments" do
      assert [m1, m2, m3] =
               statement_errors(
                 ~s[http.get(); sut.a.http.delete("/x", {}, {}); sut.a.http.post("/x", 1, {}, {});]
               )

      assert m1 =~ "http.get takes a URL and an optional options object, got 0 arguments (C113)"
      assert m2 =~ "http.delete takes a URL and an optional options object, got 3 arguments (C113)"

      assert m3 =~
               "http.post takes a URL, an optional body and an optional options object, got 4 arguments (C113)"
    end

    test "standalone http needs a full URL, a target needs a path (C114)" do
      assert [m1, m2, m3] =
               statement_errors(~s[http.get("/api/health"); http.get("ftp://x.io"); sut.a.http.get("api");])

      assert m1 =~ ~s[http.get without a target needs a full http:// or https:// URL, not "/api/health"]
      assert m2 =~ ~s[not "ftp://x.io"]
      assert m3 =~ ~s[path "api" in http.get must start with "/"]
    end

    test "options: only headers and query, each once, each a JSON object (C115)" do
      assert [m1, m2, m3] =
               statement_errors(~s|sut.a.http.get("/x", { "header": {}, "query": [1], "query": {} });|)

      assert m1 =~ ~s[unknown http option "header"; use "headers" or "query" (C115)]
      assert m2 =~ ~s[http option "query" must be a JSON object (C115)]
      assert m3 =~ ~s[duplicate http option "query"]
    end

    test "a body is a JSON value or a string, not a unit literal (C123)" do
      assert statement_errors("""
             sut.a.http.post("/x", { "id": 1 }); sut.a.http.put("/x", [1, 2]); sut.a.http.patch("/x", 42);
             sut.a.http.post("/x", true); sut.a.http.post("/x", "text"); sut.a.http.post("/x", \"""{"id": 1}\""");
             sut.a.http.post("/x", body); sut.a.http.post("/x", "", { "headers": { "Content-Type": "a/b" } });
             """) == []

      for body <- ~w(5s 10J 2kW 1gCO2e 50vu 50%) do
        assert [message] = statement_errors(~s[sut.a.http.post("/x", #{body});]), body
        assert message =~ "the body of http.post must be a JSON value or a string, not #{body} (C123)"
      end
    end

    test "options must be a JSON object; the 2nd argument of post is the body (C113, C115)" do
      assert [message] = statement_errors(~s[sut.a.http.get("/x", "/y"); sut.a.http.post("/x", "/y");])
      assert message =~ "the options of http.get must be a JSON object (C115)"
    end
  end

  describe "bare expressions must be calls (C63)" do
    test "calls, list operations and metrics are allowed" do
      assert statement_errors("""
             log(1); sut.euCentral.http.post("/cart", body); f(1)(2); xs.map(\\x -> x);
             latency.p95();
             """) == []
    end

    test "anything else is an error" do
      for expr <- [
            "x + 1",
            "x",
            "1",
            "\"s\"",
            "a.b",
            "a[0]",
            "-f(1)",
            "f(1) == 2",
            "(match a { _ => 1 })",
            "\\x -> f(x)",
            "[f(1)]"
          ] do
        assert [message] = statement_errors("#{expr};"), expr
        assert message =~ "a bare expression must be a call"
      end
    end

    test "inside nested blocks too" do
      assert [_, _, _] = statement_errors("if a { x; } else { while b { y; } } match c { _ => { z; } }")
    end
  end

  describe "return only inside a function (C74)" do
    test "allowed anywhere inside a function body" do
      assert errors("""
             TestSuite S {
               Functions {
                 fn f(n: Int): Int {
                   if n < 1 { return 0; }
                   for x in xs { while true { return 1; } }
                   match n { _ => { return 2; } }
                   return;
                 }
               }
               Load { }
               Test T { Actions { } Verify { } }
             }
             """) == []
    end

    test "rejected in every phase, also nested" do
      source = """
      TestSuite S {
        Load { }
        Test T {
          Setup { return; }
          Actions { if true { return 1; } }
          Verify { match a { _ => { return; } } }
          Cleanup { return; }
        }
      }
      """

      assert [_, _, _, _] = errors = errors(source)
      assert Enum.all?(errors, &(&1 =~ "return is only allowed inside a function (C74)"))
    end
  end

  describe "naming (C46)" do
    test "camelCase names and PascalCase types are valid" do
      assert statement_errors("""
             let x = 1; let mut euCentralResponse2 = 1; let t: List<Time> = [];
             for region in regions { } let f = \\(a, bC: Fn<Response, Int>) -> a;
             match s { status => 1, _ => 2 }
             """) == []

      assert load_errors("curves { easeIn(t, cyclesX) = t; }") == []
    end

    test "declared names must be camelCase" do
      source = """
      TestSuite S {
        Functions { fn Fetch(Region: Target): Unit { } }
        Load { curves { Wave(t, my_cycles) = t; } }
        Test T {
          Actions {
            let MyVar = 1;
            let mut snake_case = 1;
            for I in xs { }
            let f = \\(A) -> 1;
            match s { Code => 1 }
          }
          Verify { }
        }
      }
      """

      assert [
               "2:15: function name Fetch must be camelCase (C46)",
               "2:24: parameter name Region must be camelCase (C46)",
               "3:19: curve name Wave must be camelCase (C46)",
               "3:19: curve parameter name my_cycles must be camelCase (C46)",
               "6:7: variable name MyVar must be camelCase (C46)",
               "7:7: variable name snake_case must be camelCase (C46)",
               "8:7: loop variable name I must be camelCase (C46)",
               "9:17: parameter name A must be camelCase (C46)",
               "10:17: match binding name Code must be camelCase (C46)"
             ] = errors(source)
    end

    test "type names must be PascalCase, type arguments included" do
      assert [
               "2:50: type name time must be PascalCase (C46)",
               "2:72: type name response must be PascalCase (C46)"
             ] =
               errors(
                 suite_with_functions(
                   "fn f(a: List<Time>): Unit { let x: time = 1; let y: List<response> = []; }"
                 )
               )
    end

    test "suite, Test and target names are not checked" do
      assert errors("""
             TestSuite my_suite {
               Load { distribution { eu_central 100%; } stages [ 1vu for 1iter ] }
               Test lower_case { Actions { } Verify { } }
             }
             """) == []
    end
  end

  defp suite_with_functions(fns) do
    """
    TestSuite S {
      Functions { #{fns} }
      Load { }
      Test T { Actions { } Verify { } }
    }
    """
  end
end
