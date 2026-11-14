defmodule PerfLang.ParserTest do
  use ExUnit.Case, async: true

  import PerfLang.TestHelpers
  alias PerfLang.{AST, Error}

  describe "grammar" do
    test "yecc reports no conflicts" do
      out = Path.join(System.tmp_dir!(), "perflang_parser_check.erl")

      assert {:ok, _} =
               :yecc.file(~c"src/perflang_parser.yrl",
                 parserfile: String.to_charlist(out),
                 warnings_as_errors: true,
                 report: true
               )
    end
  end

  describe "structure (C1-C11, C53)" do
    test "suite-level Load" do
      ast = PerfLang.parse!(suite(""))
      assert %AST.TestSuite{name: "S", functions: nil, load: %AST.Load{settings: []}} = ast
      assert [%AST.Test{name: "T", load: nil, setup: nil, cleanup: nil}] = ast.tests
    end

    test "Load in every Test" do
      ast =
        PerfLang.parse!("""
        TestSuite S {
          Test A { Load { warmup 1s; } Actions { } Verify { } }
          Test B { Load { } Setup { } Actions { } Verify { } Cleanup { } }
        }
        """)

      assert ast.load == nil

      assert [%AST.Test{load: %AST.Load{}}, %AST.Test{load: %AST.Load{}, setup: %AST.Phase{kind: :setup}}] =
               ast.tests
    end

    test "a Test cannot define Load when the suite does (C11)" do
      e =
        parse_error("""
        TestSuite S {
          Load { }
          Test A { Load { } Actions { } Verify { } }
        }
        """)

      assert {e.stage, e.line, e.column} == {:parser, 3, 12}
      assert e.message =~ "unexpected \"Load\""
      assert e.message =~ "C10, C11"
    end

    test "every Test needs Load when the suite has none (C10)" do
      e =
        parse_error("""
        TestSuite S {
          Test A { Load { } Actions { } Verify { } }
          Test B { Actions { } Verify { } }
        }
        """)

      assert {e.line, e.column} == {3, 12}
    end

    test "Load is required" do
      e = parse_error("TestSuite S { Test A { Actions { } Verify { } } }")
      assert {e.line, e.column} == {1, 24}
    end

    test "phases in fixed order; Actions required (C3, C4)" do
      assert parse_error(suite_with_phases("Verify { } Actions { }")).message =~ "Verify"
      assert parse_error(suite_with_phases("Setup { }")).message =~ ~s(unexpected "}")
      assert parse_error(suite_with_phases("Actions { } Cleanup { } Verify { }")).message =~ "Verify"
      assert parse_error(suite_with_phases("Actions { } Verify { } Setup { }")).message =~ "Setup"
    end

    test "Verify is optional (C4)" do
      assert [%AST.Test{verify: nil, cleanup: nil}] =
               PerfLang.parse!(suite_with_phases("Actions { assert 1 == 1; }")).tests

      assert [%AST.Test{setup: %AST.Phase{}, verify: nil, cleanup: %AST.Phase{kind: :cleanup}}] =
               PerfLang.parse!(suite_with_phases("Setup { } Actions { } Cleanup { }")).tests

      assert [%AST.Test{verify: %AST.Phase{kind: :verify}}] =
               PerfLang.parse!(suite_with_phases("Actions { } Verify { }")).tests
    end

    test "at least one Test (C6)" do
      assert parse_error("TestSuite S { Load { } }").message =~ ~s(unexpected "}")
    end

    test "Functions comes first (C53)" do
      ast =
        PerfLang.parse!("""
        TestSuite S {
          Functions { fn f(a: Int, b: List<Fn<Int, Int>>): Unit { } }
          Load { }
          Test T { Actions { } Verify { } }
        }
        """)

      assert [%AST.FnDeclaration{name: "f", params: [a, b], return_type: %AST.Type{name: "Unit"}}] =
               ast.functions

      assert strip(a) == %{name: "a", type: %{name: "Int", args: []}}

      assert strip(b.type) == %{
               name: "List",
               args: [%{name: "Fn", args: [%{name: "Int", args: []}, %{name: "Int", args: []}]}]
             }
    end

    test "empty Functions block" do
      ast = PerfLang.parse!("TestSuite S { Functions { } Load { } Test T { Actions { } Verify { } } }")
      assert ast.functions == []
    end

    test "names must be identifiers, not strings (C7)" do
      assert parse_error(~s(TestSuite "S" { })).message =~ "unexpected string"
    end

    test "unexpected end of input" do
      e = parse_error("TestSuite S {\n  Load { }\n")
      assert e.message == "unexpected end of input"
      assert {e.line, e.column} == {3, 1}
    end
  end

  defp suite_with_phases(phases), do: "TestSuite S { Load { } Test T { #{phases} } }"

  describe "Config (C97-C100, C119-C122)" do
    defp config!(config) do
      %AST.TestSuite{config: config} =
        PerfLang.parse!("TestSuite S { #{config} Load { } Test T { Actions { } Verify { } } }")

      config
    end

    test "a target has a host, which stays usable as a name (C156)" do
      assert {:ok, %AST.TestSuite{config: %AST.Config{sections: [%AST.Sut{targets: [target]}]}}} =
               PerfLang.parse(
                 ~s|TestSuite S { Config { sut { db { host = "10.0.0.20"; } } } Load { } Test T { Actions { } } }|
               )

      assert %AST.SutTarget{name: "db", settings: [%AST.Host{value: %AST.StringLiteral{value: "10.0.0.20"}}]} =
               target

      assert [%AST.Let{name: "host"}] = statements!("let host = 1;")
    end

    test "metrics with selectors, and metricsPort (C159)" do
      source = ~s|Config { sut { a { metrics = [cpu[0, 1], power, disk["sda"],]; metricsPort = 9400; } } }|
      assert {:ok, %AST.Config{sections: [%AST.Sut{targets: [target]}]}} = PerfLang.parse_config(source)

      assert %AST.SutTarget{settings: [%AST.TargetMetrics{metrics: metrics}, %AST.MetricsPort{value: port}]} =
               target

      assert [
               %AST.MetricSource{name: "cpu", devices: [_, _]},
               %AST.MetricSource{name: "power", devices: []},
               disk
             ] = metrics

      assert %AST.MetricSource{name: "disk", devices: [%AST.StringLiteral{value: "sda"}]} = disk
      assert %AST.NumberLiteral{value: 9400} = port
    end

    test "the monitoring section (C158, C161)" do
      source =
        ~s|Config { monitoring { interval = 500ms; port = 9100; path = "/m"; format = json; carbonIntensity = 380.5gCO2e/kWh; } }|

      assert {:ok, %AST.Config{sections: [%AST.Monitoring{settings: settings}]}} =
               PerfLang.parse_config(source)

      assert [
               %AST.MonitorInterval{value: %AST.TimeLiteral{raw: "500ms"}},
               %AST.MonitorPort{value: %AST.NumberLiteral{value: 9100}},
               %AST.MonitorPath{value: %AST.StringLiteral{value: "/m"}},
               %AST.MonitorFormat{value: "json"},
               %AST.CarbonIntensity{value: %AST.CarbonIntensityLiteral{value: 380.5, raw: "380.5gCO2e/kWh"}}
             ] = settings
    end

    test "topics in a target, and mqtt in monitoring (C163)" do
      source = """
      Config {
        sut { a { metrics = [power, mem]; topics { power = "t/p"; mem = "t/m"; } } }
        monitoring {
          mqtt {
            broker = "mqtt://b:1883";
            qos = 2;
            fields { power = "ENERGY.Power"; }
          }
        }
      }
      """

      assert {:ok, %AST.Config{sections: [%AST.Sut{targets: [target]}, %AST.Monitoring{settings: [mqtt]}]}} =
               PerfLang.parse_config(source)

      assert %AST.SutTarget{settings: [_, %AST.TargetTopics{topics: [power, mem]}]} = target
      assert %AST.Topic{metric: "power", value: %AST.StringLiteral{value: "t/p"}} = power
      assert %AST.Topic{metric: "mem"} = mem

      assert %AST.Mqtt{settings: [%AST.MqttBroker{}, %AST.MqttQos{}, %AST.MqttFields{fields: [field]}]} = mqtt
      assert %AST.MetricField{metric: "power", path: %AST.StringLiteral{value: "ENERGY.Power"}} = field
    end

    test "fields in monitoring (C158)" do
      source = ~s|Config { monitoring { fields { gpu = "DCGM_FI_DEV_GPU_UTIL"; power = "node_watts"; } } }|

      assert {:ok, %AST.Config{sections: [%AST.Monitoring{settings: [fields]}]}} =
               PerfLang.parse_config(source)

      assert %AST.MonitorFields{fields: [%AST.MetricField{metric: "gpu"}, %AST.MetricField{metric: "power"}]} =
               fields
    end

    test "samples in output (C173)" do
      source =
        ~s|TestSuite S { Config { output { samples { file = "s.jsonl"; } } } Load { } Test T { Actions { } } }|

      assert {:ok, %AST.TestSuite{config: %AST.Config{sections: [%AST.Output{settings: [samples]}]}}} =
               PerfLang.parse(source)

      assert %AST.SamplesOutput{value: %AST.StringLiteral{value: "s.jsonl"}} = samples
    end

    test "the mqtt words stay usable as names (C77)" do
      assert [
               %AST.Let{name: "topics"},
               %AST.Let{name: "mqtt"},
               %AST.Let{name: "broker"},
               %AST.Let{name: "qos"}
             ] =
               statements!("let topics = 1; let mqtt = 2; let broker = 3; let qos = 4;")
    end

    test "the monitoring words stay usable as names (C77)" do
      assert [%AST.Let{name: "path"}, %AST.Let{name: "port"}, %AST.Let{name: "format"}] =
               statements!("let path = 1; let port = 2; let format = 3;")
    end

    test "a carbon intensity is only the setting (C161)" do
      assert parse_error(suite("let a = 380gCO2e/kWh;")).message =~
               "only the carbonIntensity setting in monitoring"
    end

    test "an external configuration file holds one Config block (C157)" do
      assert {:ok, %AST.Config{sections: [%AST.Sut{targets: [_, _]}]}} =
               PerfLang.parse_config("""
               // staging
               Config {
                 sut {
                   a { baseUrl = "http://a"; }
                   b { host = "10.0.0.20"; }
                 }
               }
               """)
    end

    test "a configuration file is not a suite, and a suite is not a configuration file (C157)" do
      assert {:error, %Error{stage: :parser, line: 1, column: 1}} = PerfLang.parse("Config { }")
      assert {:error, %Error{message: message}} = PerfLang.parse_config("TestSuite S { }")
      assert message =~ ~s(unexpected "TestSuite")
      assert {:error, %Error{message: "unexpected end of input"}} = PerfLang.parse_config("")
      assert {:error, %Error{message: message}} = PerfLang.parse_config("Config { } Config { }")
      assert message =~ ~s(unexpected "Config")
    end

    test "errors in a configuration file carry the file name (C157)" do
      path = Path.join(System.tmp_dir!(), "broken.perfcfg")
      File.write!(path, "Config {\n  sut { a { nope = 1; } }\n}")
      assert {:error, %Error{file: ^path, line: 2}} = PerfLang.parse_config_file(path)
    end

    test "sut with named targets, each with a baseUrl" do
      assert %AST.Config{loc: {1, 15}, sections: [%AST.Sut{targets: [eu, us]}]} =
               config!("""
               Config {
                 sut {
                   euCentral { baseUrl = "https://eu.api.examp.com"; }
                   usEast    { baseUrl = "https://us.api.examp.com"; }
                 }
               }
               """)

      assert %AST.SutTarget{name: "euCentral", settings: [%AST.BaseUrl{value: url}]} = eu
      assert %AST.StringLiteral{value: "https://eu.api.examp.com", raw: false} = url
      assert %AST.SutTarget{name: "usEast"} = us
    end

    test "output with a requests block and a summary file (C119, C122)" do
      assert %AST.Config{sections: [%AST.Sut{}, %AST.Output{settings: [requests, summary]}]} =
               config!("""
               Config {
                 sut { }
                 output {
                   requests {
                     file          = "results/requests.jsonl";
                     fields        = [time, status, latency, outcome,];
                     includeWarmup = true;
                   }
                   summary = "results/summary.json";
                 }
               }
               """)

      assert %AST.RequestsOutput{settings: [file, fields, warmup]} = requests
      assert %AST.OutputFile{value: %AST.StringLiteral{value: "results/requests.jsonl"}} = file
      assert %AST.OutputFields{fields: names} = fields
      assert Enum.map(names, & &1.name) == ~w(time status latency outcome)
      assert %AST.IncludeWarmup{value: %AST.BoolLiteral{value: true}} = warmup
      assert %AST.SummaryOutput{value: %AST.StringLiteral{value: "results/summary.json"}} = summary
    end

    test "output and requests may be empty; fields may be [] (rejected after parsing)" do
      assert %AST.Config{sections: [%AST.Output{settings: []}]} = config!("Config { output { } }")

      assert %AST.Config{sections: [%AST.Output{settings: [%AST.RequestsOutput{settings: []}]}]} =
               config!("Config { output { requests { } } }")

      assert %AST.Config{
               sections: [
                 %AST.Output{settings: [%AST.RequestsOutput{settings: [%AST.OutputFields{fields: []}]}]}
               ]
             } =
               config!("Config { output { requests { fields = []; } } }")
    end

    test "output syntax errors" do
      assert config_error(~s(Config { output { requests = "x.jsonl"; } })) =~ ~s(unexpected "=")
      assert config_error(~s(Config { output { requests { file "x.jsonl"; } } })) =~ "unexpected string"
      assert config_error(~s(Config { output { requests { fields = ["status"]; } } })) =~ "unexpected string"
      assert config_error(~s(Config { output { requests { includeWarmup = 1; } } })) =~ "number 1"
      assert config_error(~s(Config { output { latency = "x.json"; } })) =~ ~s(unexpected "latency")
    end

    test "output, requests, summary, file, fields and includeWarmup stay usable as names (C77)" do
      assert show(expr!("output.requests + summary + file + fields + includeWarmup")) ==
               "((((output.requests + summary) + file) + fields) + includeWarmup)"
    end

    test "Config is optional; Config, sut and targets may be empty" do
      assert config!("") == nil
      assert %AST.Config{sections: []} = config!("Config { }")
      assert %AST.Config{sections: [%AST.Sut{targets: []}]} = config!("Config { sut { } }")

      assert %AST.Config{sections: [%AST.Sut{targets: [%AST.SutTarget{settings: []}]}]} =
               config!("Config { sut { a { } } }")
    end

    test "Config comes first, before Functions" do
      ast =
        PerfLang.parse!("TestSuite S { Config { } Functions { } Load { } Test T { Actions { } Verify { } } }")

      assert %AST.TestSuite{config: %AST.Config{}, functions: []} = ast

      e = parse_error("TestSuite S { Functions { } Config { } Load { } Test T { Actions { } Verify { } } }")
      assert {e.line, e.column} == {1, 29}
      assert e.message =~ ~s(unexpected "Config")
      assert e.message =~ "C97"
    end

    test "Config is not allowed in a Test" do
      e = parse_error("TestSuite S { Test T { Config { } Load { } Actions { } Verify { } } }")
      assert e.message =~ ~s(unexpected "Config")
    end

    defp config_error(config),
      do: parse_error("TestSuite S { #{config} Load { } Test T { Actions { } Verify { } } }").message

    test "baseUrl needs \"=\", a quoted string and \";\" (C99)" do
      assert config_error(~s(Config { sut { a { baseUrl "x"; } } })) =~ "unexpected string"
      assert config_error(~s(Config { sut { a { baseUrl = 1; } } })) =~ "number 1"
      assert config_error(~s(Config { sut { a { baseUrl = """x"""; } } })) =~ "raw string"
      assert config_error(~s(Config { sut { a { baseUrl = "x" } } })) =~ ~s(unexpected "})
    end

    test "baseUrl belongs in a target, not directly in sut or Config" do
      assert config_error(~s(Config { sut { baseUrl = "x"; } })) =~ ~s(unexpected "=")
      assert config_error(~s(Config { baseUrl = "x"; })) =~ ~s(unexpected "baseUrl")
    end

    test "sut and baseUrl stay usable as names; Config is reserved (C77)" do
      assert show(expr!("sut.euCentral.http.get(baseUrl)")) == "sut.euCentral.http.get(baseUrl)"
      assert parse_error(suite("let Config = 1;")).message =~ "Config is a reserved word"
    end
  end

  describe "Load settings (C12-C38, C58, C61, C78-C87)" do
    test "settings in any order, kept in source order, duplicates allowed for the Validator" do
      settings = load_settings!("thinkTime 3s; warmup 2m; warmup 1m; stopIf true; stopIf false;")

      assert [%AST.ThinkTime{}, %AST.Warmup{}, %AST.Warmup{}, %AST.StopIf{}, %AST.StopIf{}] = settings
    end

    test "warmup and thinkTime need a Time" do
      assert parse_error(suite("", "warmup 5;")).message =~ "number 5"
      assert parse_error(suite("", "warmup 5J;")).message =~ "Energy 5J"
    end

    test "requestTimeout takes a Time, in any position (C96)" do
      assert [%AST.Warmup{}, %AST.RequestTimeout{value: %AST.TimeLiteral{raw: "5s"}}, %AST.ThinkTime{}] =
               load_settings!("warmup 1m; requestTimeout 5s; thinkTime 3s;")

      assert [%AST.RequestTimeout{value: %AST.TimeLiteral{raw: "1m30s"}}, %AST.Retry{}] =
               load_settings!("requestTimeout 1m30s; retry { attempts 3; }")

      assert parse_error(suite("", "requestTimeout 5;")).message =~ "number 5"
      assert parse_error(suite("", "requestTimeout 5s")).message =~ ~s(unexpected "})
    end

    test "curves" do
      [%AST.Curves{definitions: defs}] =
        load_settings!(
          "curves { customLinear(t) = t; wave(t, cycles) = t + 0.1 * sin(2 * pi * cycles * t); k() = 1; }"
        )

      assert [%AST.CurveDefinition{name: "customLinear", params: ["t"]}, wave, k] = defs
      assert wave.params == ["t", "cycles"]
      assert show(wave.body) == "(t + (0.1 * sin((((2 * pi) * cycles) * t))))"
      assert k.params == []
    end

    test "empty curves and retry blocks, no ';' after blocks (C79, C84)" do
      assert [%AST.Curves{definitions: []}, %AST.Retry{entries: []}] = load_settings!("curves { } retry { }")
      assert parse_error(suite("", "curves { };")).message =~ ~s(unexpected ";")
    end

    test "stages" do
      [%AST.Stages{stages: stages}] =
        load_settings!(
          "stages [ 50vu in 30s exp, 100vu in 1m customLinear, 200vu in 1m wave(3), 300vu for 5m, 0vu in 7m30s, 10vu in 1s linear() ]"
        )

      assert [
               %AST.RampStage{
                 users: %AST.UsersLiteral{value: 50},
                 curve: %AST.CurveRef{name: "exp", args: nil}
               },
               %AST.RampStage{curve: %AST.CurveRef{name: "customLinear"}},
               %AST.RampStage{curve: %AST.CurveRef{name: "wave", args: [%AST.NumberLiteral{value: 3}]}},
               %AST.HoldStage{users: %AST.UsersLiteral{value: 300}, duration: %AST.TimeLiteral{raw: "5m"}},
               %AST.RampStage{curve: nil, duration: %AST.TimeLiteral{raw: "7m30s"}},
               %AST.RampStage{curve: %AST.CurveRef{name: "linear", args: []}}
             ] = stages
    end

    test "stages: at least one, trailing comma allowed, no ';' after ] (C21-C23)" do
      assert [%AST.Stages{stages: [_]}] = load_settings!("stages [ 1vu for 1s, ]")
      assert parse_error(suite("", "stages [ ]")).message =~ ~s(unexpected "]")
      assert parse_error(suite("", "stages [ 1vu for 1s ];")).message =~ ~s(unexpected ";")
    end

    test "now stages, anywhere in stages (C127)" do
      [%AST.Stages{stages: stages}] =
        load_settings!("stages [ 10vu now, 100vu in 2m, 500vu now, 500vu for 1m ]")

      assert [
               %AST.NowStage{users: %AST.UsersLiteral{value: 10}},
               %AST.RampStage{},
               %AST.NowStage{users: %AST.UsersLiteral{value: 500}},
               %AST.HoldStage{}
             ] = stages

      assert parse_error(suite("", "stages [ 10vu now 1s ]")).message =~ "unexpected"
      assert parse_error(suite("", "stages [ 10vu now exp ]")).message =~ "unexpected"
    end

    test "now stays usable as a name (C77, C127)" do
      assert {:ok, _} = PerfLang.parse("TestSuite S { Test T { Load { } Actions { let now = 1; } } }")
    end

    test "stages by iteration count, mixed with Time (C101)" do
      [%AST.Stages{stages: stages}] =
        load_settings!("stages [ 1vu for 10iter, 50vu in 500iter exp, 50vu for 2m, 0vu in 100iter wave(3) ]")

      assert [
               %AST.HoldStage{
                 users: %AST.UsersLiteral{value: 1},
                 duration: %AST.IterationsLiteral{value: 10, raw: "10iter"}
               },
               %AST.RampStage{
                 duration: %AST.IterationsLiteral{value: 500},
                 curve: %AST.CurveRef{name: "exp"}
               },
               %AST.HoldStage{duration: %AST.TimeLiteral{raw: "2m"}},
               %AST.RampStage{
                 duration: %AST.IterationsLiteral{value: 100},
                 curve: %AST.CurveRef{name: "wave"}
               }
             ] = stages
    end

    test "a count per user in a hold stage (C175)" do
      [%AST.Stages{stages: [hold, ramp]}] = load_settings!("stages [ 20vu for 1iter/vu, 5vu in 10iter ]")

      assert %AST.HoldStage{
               users: %AST.UsersLiteral{value: 20},
               duration: %AST.IterationsLiteral{value: 1, raw: "1iter/vu", per_user: true}
             } = hold

      assert %AST.RampStage{duration: %AST.IterationsLiteral{value: 10, per_user: false}} = ramp
    end

    test "an iteration count is only a stage length (C101, C102)" do
      e = parse_error(suite("let n = 10iter;"))
      assert e.message =~ "unexpected iteration count 10iter"
      assert e.message =~ "only a stage length"
      assert parse_error(suite("let n = 1iter/vu;")).message =~ "unexpected iteration count 1iter/vu"
      assert parse_error(suite("", "warmup 10iter;")).message =~ "iteration count 10iter"
      assert parse_error(suite("", "stages [ 10iter for 1s ]")).message =~ "iteration count 10iter"
    end

    test "a hold stage takes no curve (C26)" do
      assert parse_error(suite("", "stages [ 1vu for 1s exp ]")).message =~ "name exp"
    end

    test "stage users need vu (C94)" do
      assert parse_error(suite("", "stages [ 50 in 1s ]")).message =~ "number 50"
    end

    test "in and for are reserved (C27)" do
      assert parse_error(suite("", "stages [ 1vu in 1s for ]")).message =~ ~s(unexpected "for")
      assert parse_error(suite("", "curves { for(t) = t; }")).message =~ ~s(unexpected "for")
    end

    test "distribution" do
      [%AST.Distribution{entries: [eu, us]}] =
        load_settings!("distribution { euCentral 33.33%; usEast 66.67%; }")

      assert %AST.DistributionEntry{target: "euCentral", percentage: %AST.PercentageLiteral{hundredths: 3333}} =
               eu

      assert us.percentage.value == 66.67
      assert parse_error(suite("", "distribution { }")).message =~ ~s(unexpected "}")
    end

    test "retry" do
      [%AST.Retry{entries: entries}] =
        load_settings!("retry { backoff linear; attempts 3; delay 500ms; backoff fixed; }")

      assert [
               %AST.Backoff{strategy: :linear},
               %AST.Attempts{value: %AST.NumberLiteral{value: 3}},
               %AST.Delay{value: %AST.TimeLiteral{raw: "500ms"}},
               %AST.Backoff{strategy: :fixed}
             ] = entries

      assert parse_error(suite("", "retry { attempts 1.5; }")).message =~ "number 1.5"
      assert parse_error(suite("", "retry { backoff exp; }")).message =~ "name exp"
    end

    test "stopIf takes any expression" do
      [%AST.StopIf{condition: c}] = load_settings!("stopIf errors.rate() > 5% || latency.p99() > 2s;")
      assert %AST.Binary{op: :||} = c
    end
  end

  describe "expressions (C39, C62)" do
    test "precedence, loosest first: || && comparisons + - * / unary - ^ postfix" do
      assert show(expr!("a || b && c == d + e * f ^ g")) == "(a || (b && (c == (d + (e * (f ^ g))))))"
      assert show(expr!("a * b + c * d")) == "((a * b) + (c * d))"
      assert show(expr!("-a.b(c)[d] * 2")) == "((-a.b(c)[d]) * 2)"
    end

    test "unary minus binds looser than ^" do
      assert show(expr!("-2^2")) == "(-(2 ^ 2))"
      assert show(expr!("2^-1")) == "(2 ^ (-1))"
    end

    test "! binds like unary minus, tighter than comparisons (C147)" do
      assert show(expr!("!a == b")) == "((!a) == b)"
      assert show(expr!("!a && b")) == "((!a) && b)"
      assert show(expr!("!a.b(c)")) == "(!a.b(c))"
      assert show(expr!("a != !b")) == "(a != (!b))"
    end

    test "! starts a match arm and a statement expression (C147)" do
      assert [%AST.Let{value: %AST.Match{arms: [%{body: %AST.Unary{op: :!}}, _]}}] =
               statements!("let x = match a { 1 => !b, _ => c };")

      assert [%AST.ExpressionStatement{expression: %AST.Unary{op: :!}}] = statements!("!f();")
    end

    test "left-associative + - * / && ||, right-associative ^" do
      assert show(expr!("a - b - c")) == "((a - b) - c)"
      assert show(expr!("a / b / c")) == "((a / b) / c)"
      assert show(expr!("a || b || c")) == "((a || b) || c)"
      assert show(expr!("a ^ b ^ c")) == "(a ^ (b ^ c))"
    end

    test "comparisons do not chain" do
      e = parse_error(suite("let x = a < b < c;"))
      assert e.message =~ ~s(unexpected "<")
    end

    test "parentheses" do
      assert show(expr!("(a + b) * c")) == "((a + b) * c)"
    end

    test "member access and calls chain (C45)" do
      assert show(expr!(~s|sut.euCentral.http.get("/products")|)) == ~s|sut.euCentral.http.get("/products")|
    end

    test "indexing (C68)" do
      assert show(expr!(~s(body["items"][0]["price"]))) == ~s(body["items"][0]["price"])
    end

    test "operator locations" do
      %AST.Binary{loc: loc, left: %AST.Var{loc: left_loc}} = expr!("a + b")
      # "let x = a + b;" sits inside the Actions block on line 4.
      assert {elem(left_loc, 0), elem(loc, 1) - elem(left_loc, 1)} == {4, 2}
    end

    test "contextual keywords can be names (C77)" do
      assert show(expr!("warmup + retry.delay + min(p95, max)")) == "((warmup + retry.delay) + min(p95, max))"
      assert show(expr!("requestTimeout * 2")) == "(requestTimeout * 2)"
    end

    test "reserved words cannot be names (C77)" do
      assert parse_error(suite("let match = 1;")).message =~ "match is a reserved word"
      assert parse_error(suite("let latency = 1;")).message =~ "latency is a reserved word"
      assert parse_error(suite("let asserts = 1;")).message =~ "asserts is a reserved word"
      assert show(expr!("failed + response.failed")) == "(failed + response.failed)"
      assert parse_error(suite("let x = errors;")).message =~ ~s(unexpected ";")
    end

    test "metric group names may follow \".\" as member names (C111)" do
      assert show(expr!("response.latency")) == "response.latency"
      assert show(expr!("a.errors.count")) == "a.errors.count"
      assert show(expr!("sut.euCentral.latency.p95()")) == "sut.euCentral.latency.p95()"
      assert %AST.Metric{group: :latency} = expr!("latency.p95()")

      for name <- ~w(throughput energy power carbon asserts checks) do
        assert %AST.Member{name: ^name} = expr!("a.#{name}")
      end
    end

    test "http calls, standalone and on a target (C112)" do
      assert %AST.Call{callee: %AST.Member{object: %AST.Http{}, name: "get"}} =
               expr!(~s[http.get("https://x.io")])

      assert show(expr!(~s[sut.euCentral.http.post("/cart", body)])) ==
               ~s[sut.euCentral.http.post("/cart", body)]

      assert show(expr!("region.http.head(\"/\").status")) == ~s[region.http.head("/").status]
      assert show(expr!("response.http")) == "response.http"
      assert parse_error(suite("let http = 1;")).message =~ "http is a reserved word"
      assert parse_error(suite("for http in xs { }")).message =~ "http is a reserved word"
    end

    test "literals" do
      assert %AST.TimeLiteral{
               parts: [%AST.TimePart{unit: :m, value: 1}, %AST.TimePart{unit: :s, value: 30.5}]
             } = expr!("1m30.5s")

      assert %AST.EnergyLiteral{value: 0.5, unit: :kWh} = expr!("0.5kWh")
      assert %AST.PowerLiteral{value: 2, unit: :kW} = expr!("2kW")
      assert %AST.CarbonLiteral{value: 2.5, unit: :gCO2e} = expr!("2.5gCO2e")
      assert %AST.UsersLiteral{value: 300} = expr!("300vu")
      assert %AST.PercentageLiteral{value: 70, hundredths: 7000} = expr!("70%")
      assert %AST.NumberLiteral{value: 0.5, raw: "0.5"} = expr!("0.5")
      assert %AST.StringLiteral{value: "a\nb", raw: false} = expr!(~S("a\nb"))
      assert %AST.StringLiteral{value: "a\\nb", raw: true} = expr!(~S("""a\nb"""))
      assert %AST.BoolLiteral{value: true} = expr!("true")
    end

    test "null only as a JSON value (C69)" do
      assert parse_error(suite("let x = null;")).message =~ "null"
      assert %AST.JsonArray{items: [%AST.Null{}]} = expr!("[null]")
    end
  end

  describe "metrics (C59, C60)" do
    test "every group and measurement" do
      for {src, group, m} <- [
            {"latency.p50()", :latency, :p50},
            {"latency.max()", :latency, :max},
            {"throughput.perSecond()", :throughput, :perSecond},
            {"errors.rate()", :errors, :rate},
            {"errors.count()", :errors, :count},
            {"errors.timeouts()", :errors, :timeouts},
            {"errors.connectionErrors()", :errors, :connectionErrors},
            {"errors.assertFailures()", :errors, :assertFailures},
            {"energy.perUser()", :energy, :perUser},
            {"power.peak()", :power, :peak},
            {"power.mean()", :power, :mean},
            {"carbon.perRequest()", :carbon, :perRequest},
            {"asserts.failed()", :asserts, :failed},
            {"asserts.rate()", :asserts, :rate},
            {"checks.failed()", :checks, :failed},
            {"checks.rate()", :checks, :rate},
            {"errors.checkFailures()", :errors, :checkFailures}
          ] do
        assert %AST.Metric{group: ^group, measurement: ^m, argument: nil} = expr!(src)
      end
    end

    test "percentile takes a number" do
      assert %AST.Metric{measurement: :percentile, argument: %AST.NumberLiteral{value: 99.9}} =
               expr!("latency.percentile(99.9)")
    end

    test "CPU is read through targets, without new grammar (C109)" do
      assert show(expr!("sut.euCentral.cpu.max()")) == "sut.euCentral.cpu.max()"
      assert show(expr!("sut.cpu.mean()")) == "sut.cpu.mean()"
      assert show(expr!("loadGenerator.cpu.max()")) == "loadGenerator.cpu.max()"
      assert %AST.Let{name: "cpu"} = hd(statements!("let cpu = 1;"))
    end

    test "unknown measurement for a group" do
      assert parse_error(suite("let x = power.p95();")).message =~ ~s(unexpected "p95")
      assert parse_error(suite("let x = latency.p95;")).message =~ ~s(unexpected ";")
    end

    test "a metric result can be used further" do
      assert %AST.Binary{op: :>, left: %AST.Metric{}} = expr!("latency.p95() > 10J")
    end
  end

  describe "lambdas and list operations (C88-C93)" do
    test "single parameter" do
      %AST.ListOperation{op: :map, receiver: %AST.Var{name: "responses"}, init: nil, function: f} =
        expr!(~S|responses.map(\r -> r.status)|)

      assert %AST.Lambda{params: [%AST.LambdaParam{name: "r", type: nil}], body: %AST.Member{name: "status"}} =
               f
    end

    test "several parameters, with types" do
      %AST.ListOperation{op: :fold, init: %AST.NumberLiteral{value: 0}, function: f} =
        expr!(~S[prices.fold(0, \(sum, p: Number) -> sum + p)])

      assert [%AST.LambdaParam{name: "sum"}, %AST.LambdaParam{name: "p", type: %AST.Type{name: "Number"}}] =
               f.params
    end

    test "chaining and named functions" do
      %AST.ListOperation{op: :map, function: %AST.Var{name: "checkStatus"}, receiver: inner} =
        expr!(~S[responses.filter(\r -> r.status >= 500).map(checkStatus)])

      assert %AST.ListOperation{op: :filter} = inner
    end

    test "foldl and foldr" do
      assert %AST.ListOperation{op: :foldl} = expr!(~S[xs.foldl(0, \(acc, x) -> acc + x)])
      assert %AST.ListOperation{op: :foldr} = expr!(~S[xs.foldr(0, \(x, acc) -> x + acc)])
    end

    test "the body extends as far right as possible" do
      %AST.Lambda{body: body} = expr!(~S(\x -> x + 1 * 2 || y))
      assert show(body) == "((x + (1 * 2)) || y)"
    end

    test "lambdas as ordinary arguments and values" do
      assert %AST.Call{args: [%AST.Lambda{}, %AST.NumberLiteral{}]} = expr!(~S[apply(\x -> x, 1)])
      assert %AST.Lambda{params: [%AST.LambdaParam{type: %AST.Type{name: "Int"}}]} = expr!(~S(\x: Int -> x))
    end

    test "map takes a function value, not an arbitrary expression (C92)" do
      assert parse_error(suite("let x = xs.map(a.b);")).message =~ ~s(unexpected ".")
      assert parse_error(suite("let x = xs.fold(\\a -> a);")).message =~ ~s[unexpected ")"]
    end

    test "a lambda cannot be an operand" do
      assert parse_error(suite("let x = 1 + \\y -> y;")).message =~ ~s(unexpected "\\\\")
    end
  end

  describe "JSON (C66-C69)" do
    test "objects and arrays with expressions and trailing commas" do
      json = expr!(~s({ "id": productId, "tags": ["a", "b",], "qty": 1, "nested": {}, }))

      assert strip(json) == %{
               members: [
                 %{key: "id", value: %{name: "productId"}},
                 %{key: "tags", value: %{items: [%{value: "a", raw: false}, %{value: "b", raw: false}]}},
                 %{key: "qty", value: %{value: 1, raw: "1"}},
                 %{key: "nested", value: %{members: []}}
               ]
             }
    end

    test "keys must be quoted strings" do
      assert parse_error(suite("let x = { id: 1 };")).message =~ "name id"
      assert parse_error(suite(~s(let x = { """id""": 1 };))).message =~ "raw string"
    end

    test "JSON can be indexed and called on" do
      assert %AST.Index{object: %AST.JsonObject{}} = expr!(~s({"a": 1}["a"]))
      assert %AST.Index{object: %AST.JsonArray{}} = expr!("[1, 2][0]")
    end
  end

  describe "statements (C43-C47, C50, C63, C70, C76)" do
    test "let, let mut, type annotations" do
      assert [
               %AST.Let{name: "a", mutable: false, type: nil},
               %AST.Let{name: "b", mutable: true, type: nil},
               %AST.Let{name: "c", mutable: false, type: %AST.Type{name: "Time"}},
               %AST.Let{
                 name: "d",
                 mutable: true,
                 type: %AST.Type{name: "List", args: [%AST.Type{name: "Time"}]}
               }
             ] = statements!("let a = 1; let mut b = 2; let c: Time = 5s; let mut d: List<Time> = [];")
    end

    test "List<Time>= needs a space, as the grammar notes" do
      assert parse_error(suite("let d: List<Time>= [];")).message =~ ~s(unexpected ">=")
    end

    test "assignment to a whole variable only (C76)" do
      assert [%AST.Assign{name: "x", value: %AST.Binary{op: :+}}] = statements!("x = x + 1;")
      assert parse_error(suite("a.b = 1;")).message =~ ~s(unexpected "=")
    end

    test "assert" do
      assert [%AST.Assert{condition: %AST.Binary{op: :==}}] = statements!("assert response.status == 200;")
    end

    test "check, the soft assert (C129)" do
      assert [%AST.Check{condition: %AST.Binary{op: :==}}, %AST.Assert{}] =
               statements!("check response.status == 200; assert x;")

      assert parse_error(suite("check;")).message =~ ~s(unexpected ";")
      assert parse_error(suite("let check = 1;")).message =~ "check"
      assert parse_error(suite("let checks = 1;")).message =~ "checks"
    end

    test "expression statements keep any expression; C63 is checked after parsing" do
      assert [
               %AST.ExpressionStatement{expression: %AST.Call{}},
               %AST.ExpressionStatement{expression: %AST.Binary{}},
               %AST.ExpressionStatement{expression: %AST.Call{callee: %AST.Member{object: %AST.JsonArray{}}}},
               %AST.ExpressionStatement{expression: %AST.Unary{}}
             ] = statements!(~s|sut.euCentral.http.post("/cart", body); x + 1; [1].len(); -f();|)
    end

    test "sleep is a plain call, resolved after parsing (C133)" do
      assert [
               %AST.ExpressionStatement{
                 expression: %AST.Call{callee: %AST.Var{name: "sleep"}, args: [%AST.TimeLiteral{raw: "2s"}]}
               }
             ] = statements!("sleep(2s);")
    end

    test "random is a plain member call that chains (C134)" do
      assert %AST.Index{
               object: %AST.Call{callee: %AST.Member{object: %AST.Index{}, name: "random"}, args: []},
               index: %AST.StringLiteral{value: "id"}
             } = expr!(~s|body["products"].random()["id"]|)

      assert %AST.Call{callee: %AST.Member{name: "random"}, args: [%AST.NumberLiteral{raw: "5"}]} =
               expr!("items.random(5)")
    end

    test "list methods are plain member calls (C137, C145)" do
      assert [
               %AST.ExpressionStatement{expression: %AST.Call{callee: %AST.Member{name: "add"}, args: [_]}},
               %AST.Let{value: %AST.Call{callee: %AST.Member{name: "length"}, args: []}},
               %AST.Let{value: %AST.Call{callee: %AST.Member{name: "contains"}, args: [_]}}
             ] = statements!("ids.add(id); let n = ids.length(); let b = ids.contains(id);")
    end

    test "missing semicolon" do
      e = parse_error(suite("let a = 1\nlet b = 2;"))
      assert e.message == ~s(unexpected "let")
      assert e.line == 5
    end

    test "return with and without a value (placement checked after parsing, C74)" do
      assert [%AST.Return{value: nil}, %AST.Return{value: %AST.Var{}}] = statements!("return; return x;")
    end
  end

  describe "control flow (C55, C73)" do
    test "if, else if, else" do
      [%AST.If{condition: c, then: %AST.Block{statements: [_]}, else: %AST.If{else: %AST.Block{}}}] =
        statements!("if a > 1 { f(); } else if (b) { } else { g(); }")

      assert %AST.Binary{op: :>} = c
    end

    test "a { after a complete condition starts the block" do
      [%AST.If{condition: %AST.JsonObject{}, then: %AST.Block{statements: []}}] =
        statements!(~s(if {"a": 1} { }))
    end

    test "while and for" do
      assert [
               %AST.While{condition: %AST.Binary{op: :<}, body: %AST.Block{}},
               %AST.For{var: "region", iterable: %AST.Var{name: "regions"}},
               %AST.For{var: "i", iterable: %AST.Call{args: [_, _]}}
             ] =
               statements!(
                 "while attempts < 3 { attempts = attempts + 1; } for region in regions { } for i in range(0, 10) { }"
               )
    end

    test "braces are required" do
      assert parse_error(suite("if a f();")).message =~ "name f"
    end
  end

  describe "match (C75)" do
    test "match as a value, with guards and wildcard" do
      [%AST.Let{value: %AST.Match{subject: subject, arms: arms}}] =
        statements!("""
        let kind = match response.status {
          200            => "ok",
          404            => "missing",
          s if s >= 500  => "server error",
          _              => "other",
        };
        """)

      assert %AST.Member{name: "status"} = subject

      assert [
               %AST.MatchArm{
                 pattern: %AST.LiteralPattern{literal: %AST.NumberLiteral{value: 200}},
                 guard: nil
               },
               %AST.MatchArm{body: %AST.StringLiteral{value: "missing"}},
               %AST.MatchArm{pattern: %AST.BindPattern{name: "s"}, guard: %AST.Binary{op: :>=}},
               %AST.MatchArm{pattern: %AST.WildcardPattern{}}
             ] = arms
    end

    test "patterns: negative literals, unit literals, strings, bools" do
      [%AST.Let{value: %AST.Match{arms: arms}}] =
        statements!(~s(let k = match x { -1 => 1, 5s => 2, "a" => 3, true => 4, 50vu => 5 };))

      assert [
               %AST.LiteralPattern{negative: true, literal: %AST.NumberLiteral{value: 1}},
               %AST.LiteralPattern{literal: %AST.TimeLiteral{}},
               %AST.LiteralPattern{literal: %AST.StringLiteral{}},
               %AST.LiteralPattern{literal: %AST.BoolLiteral{}},
               %AST.LiteralPattern{literal: %AST.UsersLiteral{}}
             ] = Enum.map(arms, & &1.pattern)
    end

    test "a { after => always starts a block, even when empty" do
      [%AST.MatchStatement{match: %AST.Match{arms: arms}}] =
        statements!(~s|match x { 1 => { }, 2 => { log("two"); }, 3 => ({ "ok": true }), 4 => [1] }|)

      assert [
               %AST.Block{statements: []},
               %AST.Block{statements: [%AST.ExpressionStatement{}]},
               %AST.JsonObject{members: [_]},
               %AST.JsonArray{}
             ] = Enum.map(arms, & &1.body)
    end

    test "a match statement needs no ';' but accepts one" do
      assert [%AST.MatchStatement{}, %AST.MatchStatement{}, %AST.Let{}] =
               statements!("match a { _ => 1 } match b { _ => 2 }; let c = 3;")
    end

    test "a statement-level match ends at its }" do
      # The next statement starts with "(" and is not a call on the match.
      assert [
               %AST.MatchStatement{},
               %AST.ExpressionStatement{expression: %AST.Call{callee: %AST.Var{name: "f"}}}
             ] = statements!("match a { _ => g } (f)(1);")
    end

    test "match can be used inside a longer expression when parenthesised or not at statement start" do
      assert [%AST.ExpressionStatement{expression: %AST.Call{callee: %AST.Member{object: %AST.Match{}}}}] =
               statements!("(match a { _ => b }).run();")

      assert %AST.Binary{left: %AST.Match{}} = expr!("match a { _ => 1 } + 1")
    end

    test "at least one arm" do
      assert parse_error(suite("match a { }")).message =~ ~s(unexpected "}")
    end
  end
end
