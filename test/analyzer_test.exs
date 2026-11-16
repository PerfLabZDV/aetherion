defmodule PerfLang.AnalyzerTest do
  use ExUnit.Case, async: true

  alias PerfLang.{Analyzer, AST, Error}

  # Parses, validates and analyzes, and returns the formatted errors ([] when valid).
  # `config` is the source of an external configuration file.
  defp errors(source, config \\ nil) do
    {:ok, ast} = source |> PerfLang.parse!() |> PerfLang.validate()

    case Analyzer.analyze(ast, config: config && config!(config)) do
      {:ok, _} -> []
      {:error, errors} -> Enum.map(errors, &Error.format/1)
    end
  end

  defp config!(source) do
    {:ok, config} = PerfLang.parse_config(source)
    {:ok, config} = PerfLang.validate(config)
    config
  end

  defp analyzed!(source) do
    {:ok, ast} = Analyzer.analyze(PerfLang.parse!(source))
    ast
  end

  # A suite with a target `api`; every phase and block can be set.
  defp suite(parts) do
    """
    TestSuite S {
      Config {
        sut { api { baseUrl = "http://h"; metrics = [cpu, mem, disk, gpu, power]; } }
        monitoring {
          port = 9100;
          format = prometheus;
          fields { gpu = "g"; power = "p"; }
          carbonIntensity = 380gCO2e/kWh;
        }
      }
      Functions { #{parts[:functions]} }
      Load { #{parts[:load]} }
      Test T {
        Setup { #{parts[:setup]} }
        Actions { #{parts[:actions]} }
        Verify { #{parts[:verify]} }
        Cleanup { #{parts[:cleanup]} }
      }
    }
    """
  end

  defp actions(statements), do: errors(suite(actions: statements))
  defp verify(statements), do: errors(suite(verify: statements))

  defp actions_type(expression) do
    source = suite(actions: "let x = #{expression};")

    %AST.TestSuite{tests: [%AST.Test{actions: %AST.Phase{statements: [%AST.Let{value: value}]}}]} =
      analyzed!(source)

    value.type
  end

  defp assert_error(found, expected) do
    assert Enum.any?(found, &(&1 =~ expected)), "#{inspect(expected)} not in #{inspect(found)}"
  end

  test "every example and the full suite are accepted" do
    for path <- Path.wildcard("examples/*.perf") ++ ["test/fixtures/full_suite.perf"] do
      {:ok, ast} = PerfLang.parse_file(path)
      assert {:ok, %AST.TestSuite{}} = PerfLang.analyze(ast), path
    end
  end

  test "errors are all reported, sorted by position, with stage :semantic" do
    {:ok, ast} = PerfLang.parse(suite(actions: "let a = b;\n let c = d;"))
    assert {:error, [first, second]} = Analyzer.analyze(ast)
    assert %Error{stage: :semantic, message: "unknown name b"} = first
    assert %Error{stage: :semantic, message: "unknown name d"} = second
    assert {first.line, first.column} < {second.line, second.column}
  end

  describe "typed AST" do
    test "every expression gets its type" do
      assert actions_type("1") == :int
      assert actions_type("1.5") == :float
      assert actions_type("\"a\"") == :string
      assert actions_type("true") == :bool
      assert actions_type("5s") == :time
      assert actions_type("5J") == :energy
      assert actions_type("5W") == :power
      assert actions_type("5gCO2e") == :carbon
      assert actions_type("5%") == :percentage
      assert actions_type("5vu") == :users
      assert actions_type("sut.api") == :target
      assert actions_type("sut.api.http.get(\"/\")") == :response
      assert actions_type("sut.api.http.get(\"/\").latency") == :time
      assert actions_type("[1, 2]") == {:list, :int}
      assert actions_type("{ \"a\": 1 }") == :json
      assert actions_type("\\(x: Int) -> x + 1") == {:fn, [:int], :int}
    end

    test "nested nodes are typed and no type variable is left" do
      source =
        suite(
          setup: "let mut ids = []; let mut empty = [];",
          actions: ~s|ids.add(1); let n = ids.length() + 1;|
        )

      ast = analyzed!(source)

      assert [%AST.Let{value: %AST.JsonArray{type: {:list, :int}}}, %AST.Let{value: value}] =
               hd(ast.tests).setup.statements

      assert value.type == {:list, :unknown}

      [
        _add,
        %AST.Let{
          value: %AST.Binary{type: :int, left: %AST.Call{type: :int}, right: %AST.NumberLiteral{type: :int}}
        }
      ] =
        hd(ast.tests).actions.statements

      refute inspect(ast, limit: :infinity) =~ "{:var,"
    end
  end

  describe "scope (C136, C149, C150)" do
    test "Setup reaches every later phase" do
      source = suite(setup: "let a = 1;", actions: "let b = a;", verify: "let c = a;", cleanup: "let d = a;")
      assert errors(source) == []
    end

    test "Actions reaches Verify and Cleanup" do
      assert errors(suite(actions: "let a = 1;", verify: "let b = a;", cleanup: "let c = a;")) == []
    end

    test "nothing reaches back, and Verify does not reach Cleanup" do
      assert_error(errors(suite(setup: "let a = b;", actions: "let b = 1;")), "unknown name b")
      assert_error(errors(suite(verify: "let a = 1;", cleanup: "let b = a;")), "unknown name a")
    end

    test "a name is read after its declaration" do
      assert_error(actions("let a = b; let b = 1;"), "unknown name b")
      assert_error(actions("let a = a;"), "unknown name a")
    end

    test "block variables end with their block, also for Verify" do
      assert_error(actions("if true { let a = 1; } let b = a;"), "unknown name a")
      assert_error(actions("for i in range(0, 2) { } let b = i;"), "unknown name i")
      assert_error(errors(suite(actions: "if true { let a = 1; }", verify: "let b = a;")), "unknown name a")
    end

    test "variables do not cross Tests" do
      source = """
      TestSuite S {
        Load { }
        Test A { Setup { let a = 1; } Actions { } }
        Test B { Actions { let b = a; } }
      }
      """

      assert_error(errors(source), "unknown name a")
    end

    test "inner scopes shadow, also built-ins; one scope does not" do
      assert actions("let a = 1; if true { let a = \"s\"; }") == []
      assert actions("let sin = 1; let b = sin + 1;") == []
      assert errors(suite(setup: "let a = 1;", actions: "let a = \"s\";")) == []
      assert_error(actions("let a = 1; let a = 2;"), "a is already declared in this scope")
      assert_error(actions("for i in range(0, 2) { let i = 1; }"), "i is already declared in this scope")
    end

    test "a fn sees its parameters, built-ins and targets, not phase variables" do
      assert errors(suite(functions: "fn f(a: Int): Float { sut.api.http.get(\"/\"); return sqrt(a); }")) ==
               []

      source = suite(functions: "fn f(): Int { return a; }", setup: "let a = 1;")
      assert_error(errors(source), "unknown name a")
    end

    test "duplicate Test, fn and curve names" do
      source = """
      TestSuite S {
        Functions {
          fn f(): Unit { }
          fn f(): Unit { }
        }
        Load { curves { c(t) = t; c(t) = t; } }
        Test A { Actions { } }
        Test A { Actions { } }
      }
      """

      found = errors(source)
      assert_error(found, "duplicate fn f (first at 3:5) (C149)")
      assert_error(found, "duplicate curve c")
      assert_error(found, "duplicate Test A")
    end
  end

  describe "shared state (C76, C137)" do
    test "assignment needs let mut" do
      assert actions("let mut a = 1; a = 2;") == []
      assert_error(actions("let a = 1; a = 2;"), "a is not mutable; declare it with let mut (C76)")
      assert_error(actions("a = 2;"), "unknown name a")
    end

    test "Actions does not assign to Setup variables, at any depth" do
      source = suite(setup: "let mut n = 0;", actions: "n = n + 1;")
      assert_error(errors(source), "Actions cannot assign to the Setup variable n")

      source = suite(setup: "let mut n = 0;", actions: "if true { n = 1; }")
      assert_error(errors(source), "Actions cannot assign to the Setup variable n")
    end

    test "other phases may assign to Setup variables" do
      assert errors(suite(setup: "let mut n = 0; n = 1;", verify: "n = 2;", cleanup: "n = 3;")) == []
    end

    test "a shadowing Actions variable can be assigned" do
      assert errors(suite(setup: "let mut n = 0;", actions: "let mut n = 1; n = 2;")) == []
    end

    test "add collects into a let mut list" do
      assert errors(suite(setup: "let mut ids = [];", actions: "ids.add(1);")) == []
      assert errors(suite(setup: "let mut ids: List<String> = [];", actions: ~s|ids.add("a");|)) == []
    end

    test "add needs let mut and a list" do
      assert_error(
        errors(suite(setup: "let ids = [];", actions: "ids.add(1);")),
        "add needs a list declared with let mut"
      )

      assert_error(actions("let mut j: Json = []; j.add(1);"), "add needs a list declared with let mut")
      assert_error(actions("[1].add(2);"), "add needs a variable declared with let mut")
    end

    test "add takes the element type from the list" do
      assert_error(actions(~s|let mut ids: List<Int> = []; ids.add("a");|), "expected Int, got String")
      assert_error(actions(~s|let mut ids = []; ids.add(1); ids.add("a");|), "expected Int, got String")
    end
  end

  describe "types (C138, C139)" do
    test "built-in type names" do
      names =
        ~w(Bool String Json Unit Int Float Time Energy Power Carbon Percentage VirtualUsers Response Target)

      for name <- names, do: assert(errors(suite(functions: "fn f(a: #{name}): Unit { }")) == [])
      assert errors(suite(functions: "fn f(a: List<Int>, b: Fn<Int, Bool>, c: Fn<Int>): Unit { }")) == []
    end

    test "rejected type names" do
      assert_error(actions("let a: Foo = 1;"), "unknown type Foo (C138)")
      assert_error(actions("let a: Number = 1;"), "Number is not a type name; use Int or Float (C139)")
      assert_error(actions("let a: List = [1];"), "List takes one type argument")
      assert_error(actions("let a: Fn = 1;"), "Fn needs at least its return type")
      assert_error(actions("let a: Int<Int> = 1;"), "Int takes no type arguments (C138)")
    end

    test "Int widens to Float, never back" do
      assert actions("let a: Float = 1;") == []
      assert_error(actions("let a: Int = 1.5;"), "expected Int, got Float")
      assert_error(actions("let mut a = 0; a = 1.5;"), "expected Int, got Float")
    end

    test "arithmetic on numbers" do
      assert actions_type("1 + 2") == :int
      assert actions_type("1 + 2.5") == :float
      assert actions_type("4 / 2") == :float
      assert actions_type("2 ^ 2") == :float
    end

    test "statements check their types" do
      assert_error(actions("assert 1;"), "expected Bool, got Int")
      assert_error(actions("check \"a\";"), "expected Bool, got String")
      assert_error(actions("if 1 { }"), "expected Bool, got Int")
      assert_error(actions("while 1 { }"), "expected Bool, got Int")
      assert_error(actions("for x in 5 { }"), "expected a list, got Int")
    end

    test "Unit is a value of its own" do
      assert_error(actions("let a: Int = sleep(1s);"), "expected Int, got Unit")
    end
  end

  describe "lists (C140)" do
    test "a literal is a List<T> with one item type, else Json" do
      assert actions_type("[1, 2.5]") == {:list, :float}
      assert actions_type(~s|[1, "a"]|) == :json
      assert actions_type("[[1], [2]]") == {:list, {:list, :int}}
      assert actions_type("[1, null]") == :json
    end

    test "an annotation decides" do
      assert actions("let a: Json = [1, 2];") == []
      assert actions("let a: List<Float> = [1, 2];") == []
      assert actions("let a: List<Target> = [sut.api];") == []
      assert_error(actions(~s|let a: List<Int> = ["x"];|), "expected Int, got String")
    end

    test "inside JSON it is Json" do
      assert actions(~s|let a = { "items": [1, "a"], "more": [[1]] };|) == []
      assert actions(~s|sut.api.http.post("/x", [1, "a"]);|) == []
    end

    test "an empty list takes its type from its first use" do
      assert actions("let mut a = []; a = [1]; let b: Int = a[0];") == []
      assert_error(actions(~s|let mut a = []; a = [1]; a = ["x"];|), "expected Int, got String")
    end

    test "a list inside a JSON value becomes a JSON array" do
      assert actions(~s|let picks = [1, 2]; let a = { "ids": picks };|) == []
      assert actions(~s|let a = { "ids": [1, 2].map(\\x -> { "id": x }) };|) == []

      assert actions(~s|let a = { "items": [1, 2].random(2).map(\\p -> { "productId": p, "quantity": 1 }) };|) ==
               []
    end

    test "values with no JSON form are rejected" do
      assert_error(actions(~s|let a = { "t": 5s };|), "a value of type Time has no JSON form (C140)")
      assert_error(actions(~s|let a = { "t": sut.api };|), "a value of type Target has no JSON form")
      assert_error(actions(~s|let a = [5s, 1];|), "no common type (C140)")

      assert_error(
        actions(~s|let r = sut.api.http.get("/"); sut.api.http.post("/x", r);|),
        "a value of type Response has no JSON form"
      )
    end

    test "for, map, filter and fold work on lists and JSON arrays" do
      source = ~s"""
      let r = sut.api.http.get("/");
      for item in r.body["items"] { let a: Int = item["id"]; }
      let ids = r.body["items"].map(\\i -> i["id"]);
      let some = r.body["items"].filter(\\i -> i["ok"]);
      let n = r.body["items"].fold(0, \\(sum, i) -> sum + 1);
      """

      assert actions(source) == []
    end
  end

  describe "Json (C68, C141)" do
    test "converts wherever a type is expected" do
      source = ~s"""
      let j = sut.api.http.get("/").body;
      let a: Int = j["a"];
      let b: Float = j["b"];
      let c: Bool = j["c"];
      let d: String = j["d"];
      let e: List<Int> = j["e"];
      assert j["f"];
      assert j["g"] > 0;
      assert j["h"] == "ok";
      assert !j["i"];
      """

      assert actions(source) == []
    end

    test "does not convert to the unit types" do
      source = ~s|let j = sut.api.http.get("/").body; let a: Time = j["a"];|
      assert_error(actions(source), "expected Time, got Json")

      assert_error(
        actions(~s|let j = sut.api.http.get("/").body; assert j["a"] < 5s;|),
        "< cannot be used on Json and Time"
      )
    end

    test "is indexed by a String or an Int, and has no members" do
      assert_error(
        actions(~s|let j: Json = {}; let a = j[1.5];|),
        "a JSON value is indexed by a String or an Int"
      )

      assert_error(
        actions(~s|let j: Json = {}; let a = j.id;|),
        ~s|a JSON value has no member id; read it with ["id"]|
      )
    end

    test "lists are indexed by Int, and other values not at all" do
      assert actions("let a = [1]; let b: Int = a[0];") == []
      assert_error(actions(~s|let a = [1]; let b = a["x"];|), "expected Int, got String")
      assert_error(actions("let a = 1; let b = a[0];"), "Int cannot be indexed (C68)")
    end
  end

  describe "unit arithmetic (C142)" do
    test "one unit type" do
      assert actions_type("5s + 1s") == :time
      assert actions_type("5J - 1J") == :energy
      assert actions_type("2 * 5s") == :time
      assert actions_type("5s * 2") == :time
      assert actions_type("5s / 2") == :time
      assert actions_type("5s / 2s") == :float
    end

    test "DataRate (C186)" do
      assert actions_type("10MB/s") == :data_rate
      assert actions_type("10MB/s + 1kB/s") == :data_rate
      assert actions_type("2 * 1GB/s") == :data_rate
      assert actions_type("10MB/s / 1kB/s") == :float
      assert_error(actions("let a = 1MB/s + 1W;"), "+ cannot be used on DataRate and Power (C142)")
    end

    test "physical conversions" do
      assert actions_type("10J / 5s") == :power
      assert actions_type("2W * 5s") == :energy
      assert actions_type("5s * 2W") == :energy
    end

    test "anything else is rejected" do
      assert_error(actions("let a = 5s + 1;"), "+ cannot be used on Time and Int (C142)")
      assert_error(actions("let a = 5s + 1J;"), "+ cannot be used on Time and Energy (C142)")
      assert_error(actions("let a = 2 / 5s;"), "/ cannot be used on Int and Time (C142)")
      assert_error(actions("let a = 5s * 5s;"), "* cannot be used on Time and Time (C142)")
      assert_error(actions("let a = 5s ^ 2;"), "^ cannot be used on Time and Int (C142)")
      assert_error(actions("let a = 5% + 1%;"), "+ cannot be used on Percentage and Percentage (C142)")
      assert_error(actions("let a = 5vu + 1vu;"), "+ cannot be used on VirtualUsers and VirtualUsers (C142)")
      assert_error(actions("let a = [1] + [2];"), "+ cannot be used on List<Int> and List<Int> (C142)")
    end
  end

  describe "Response and http (C110, C112, C123)" do
    test "the members of a Response" do
      source = ~s|let r = sut.api.http.get("/"); let a: Int = r.status; let b: String = r.outcome;|

      assert actions(source <> ~s| let c: Time = r.latency; let d: Json = r.body; let e: Json = r.headers;|) ==
               []
    end

    test "any other member is rejected" do
      assert_error(actions(~s|let r = sut.api.http.get("/"); let a = r.foo;|), "Response has no member foo")
    end

    test "http arguments" do
      assert actions(~s|let b = { "a": 1 }; sut.api.http.post("/x", b, { "headers": {} });|) == []

      assert actions(
               ~s|sut.api.http.post("/x", "text"); sut.api.http.post("/x", 5); sut.api.http.post("/x", true);|
             ) == []

      assert_error(actions(~s|let u = 5; sut.api.http.get(u);|), "expected String, got Int")
      assert_error(actions(~s|let o = 5s; sut.api.http.get("/", o);|), "expected Json, got Time")

      assert_error(
        actions(~s|let b = 5s; sut.api.http.post("/x", b);|),
        "a value of type Time has no JSON form"
      )
    end

    test "http on a Target value and without a target" do
      assert actions(~s|let t = sut.api; t.http.get("/"); http.get("http://h/");|) == []
      assert errors(suite(functions: ~s|fn f(t: Target): Response { return t.http.get("/"); }|)) == []
      assert_error(actions(~s|let a = 1; a.http.get("/");|), "expected Target, got Int")
    end

    test "http and cpu are not values" do
      assert_error(actions("let c = sut.api.http;"), "http is not a value")
      assert_error(actions("let c = sut.api.cpu;"), "cpu is not a value")
      assert_error(actions("let c = sut;"), "sut is not a value")
      assert_error(actions("let c = loadGenerator;"), "loadGenerator is not a value")
    end
  end

  describe "targets (C143)" do
    @no_config "TestSuite S { Load { } Test T { Actions { sut.ext.http.get(\"/\"); } } }"

    test "Config targets are known" do
      assert actions(~s|sut.api.http.get("/");|) == []
    end

    test "external targets come from the configuration file" do
      assert errors(@no_config, ~s|Config { sut { ext { baseUrl = "http://e"; } } }|) == []
    end

    test "an unknown target is an error" do
      assert_error(
        errors(@no_config),
        "unknown target ext; define it in Config or the external configuration (C143)"
      )

      assert_error(actions(~s|sut.apii.http.get("/");|), "unknown target apii")
      assert_error(errors(suite(verify: "assert sut.apii.cpu.max() < 5%;")), "unknown target apii")
    end

    test "distribution targets" do
      load = "stages [ 1vu for 1s ] distribution { other 100%; }"
      assert_error(errors(suite(load: load)), "unknown target other")
      assert errors(suite(load: load), ~s|Config { sut { other { baseUrl = "http://o"; } } }|) == []
    end
  end

  describe "external configuration (C157)" do
    defp sut_names(%AST.Config{sections: sections}) do
      for %AST.Sut{targets: targets} <- sections, target <- targets, do: target.name
    end

    defp host_of(%AST.Config{sections: sections}, name) do
      for %AST.Sut{targets: targets} <- sections,
          %AST.SutTarget{name: ^name, settings: settings} <- targets,
          %AST.Host{value: value} <- settings,
          do: value.value
    end

    defp merged(source, config) do
      {:ok, ast} = Analyzer.analyze(PerfLang.parse!(source), config: config!(config))
      ast.config
    end

    @with_config """
    TestSuite S {
      Config {
        sut {
          a { baseUrl = "http://inline-a"; host = "1.1.1.1"; }
          b { baseUrl = "http://inline-b"; }
        }
        output { summary = "results/s.json"; }
      }
      Load { }
      Test T { Actions { sut.a.http.get("/"); sut.c.http.get("/"); } }
    }
    """

    test "a target in the file is added" do
      config = merged(@with_config, ~s|Config { sut { c { baseUrl = "http://c"; } } }|)
      assert Enum.sort(sut_names(config)) == ["a", "b", "c"]
    end

    test "a target in both is replaced as a whole by the file" do
      file = ~s|Config { sut { a { baseUrl = "http://file-a"; } c { baseUrl = "http://c"; } } }|
      config = merged(@with_config, file)
      assert Enum.sort(sut_names(config)) == ["a", "b", "c"]
      assert host_of(config, "a") == []
    end

    test "the suite's output section stays" do
      config = merged(@with_config, ~s|Config { sut { c { baseUrl = "http://c"; } } }|)
      assert [%AST.Output{}] = Enum.filter(config.sections, &match?(%AST.Output{}, &1))
    end

    test "a suite without Config takes the file's" do
      source = ~s|TestSuite S { Load { } Test T { Actions { sut.a.http.get("/"); } } }|
      assert sut_names(merged(source, ~s|Config { sut { a { baseUrl = "http://a"; } } }|)) == ["a"]
    end

    test "a suite with a Config but no sut takes the file's targets" do
      source = """
      TestSuite S {
        Config { output { summary = "s.json"; } }
        Load { }
        Test T { Actions { sut.a.http.get("/"); } }
      }
      """

      config = merged(source, ~s|Config { sut { a { baseUrl = "http://a"; } } }|)
      assert sut_names(config) == ["a"]
      assert [%AST.Output{}] = Enum.filter(config.sections, &match?(%AST.Output{}, &1))
    end

    test "without a file the Config stays as written" do
      ast = PerfLang.parse!(@with_config |> String.replace("sut.c", "sut.b"))
      assert {:ok, %AST.TestSuite{config: config}} = Analyzer.analyze(ast)
      assert config == ast.config
    end

    test "the example file works with an example test" do
      {:ok, config} = PerfLang.parse_config_file("examples/staging.perfcfg")
      assert {:ok, config} = PerfLang.validate(config)
      {:ok, ast} = PerfLang.parse_file("examples/t6-multi-step-user-journey.perf")
      assert {:ok, %AST.TestSuite{}} = PerfLang.analyze(ast, config: config)
    end
  end

  describe "target settings (C156)" do
    @machines ~s|Config { sut { web { baseUrl = "http://w"; } db { host = "10.0.0.20"; metrics = [cpu, mem]; } both { baseUrl = "http://b"; host = "10.0.0.30"; metrics = [power]; } empty { } } monitoring { port = 9100; format = prometheus; fields { power = "p"; } } }|

    defp with_machines(parts) do
      "TestSuite S { Load { #{parts[:load]} } Test T { Actions { #{parts[:actions]} } Verify { #{parts[:verify]} } } }"
      |> errors(@machines)
    end

    test "http needs a baseUrl" do
      assert with_machines(actions: ~s|sut.web.http.get("/"); sut.both.http.get("/");|) == []

      assert_error(
        with_machines(actions: ~s|sut.db.http.get("/");|),
        "an http call needs a target with a baseUrl, and db has none (C156)"
      )
    end

    test "distribution needs a baseUrl" do
      assert with_machines(load: "stages [ 1vu for 1s ] distribution { web 100%; }") == []

      assert_error(
        with_machines(load: "stages [ 1vu for 1s ] distribution { db 100%; }"),
        "distribution needs a target with a baseUrl, and db has none (C156)"
      )
    end

    test "a reading needs the target to list the metric (C160)" do
      assert with_machines(verify: "assert sut.db.cpu.max() < 5%; assert sut.db.mem.mean() < 5%;") == []

      assert_error(
        with_machines(verify: "assert sut.web.cpu.max() < 5%;"),
        "target web does not list cpu in its metrics (C160)"
      )

      assert_error(
        with_machines(verify: "assert sut.db.gpu.max() < 5%;"),
        "target db does not list gpu in its metrics (C160)"
      )

      assert_error(
        with_machines(verify: "assert sut.empty.mem.max() < 5%;"),
        "target empty does not list mem"
      )
    end

    test "a reading over all targets needs some target to list it (C160)" do
      assert with_machines(verify: "assert sut.cpu.max() < 5%;") == []

      assert_error(
        with_machines(verify: "assert sut.disk.max() < 5%;"),
        "no target lists disk in its metrics (C160)"
      )
    end

    test "readings have the types of C160" do
      assert with_machines(
               verify: "let a: Percentage = sut.db.mem.max(); let b: Power = sut.both.power.mean();"
             ) == []

      assert_error(
        with_machines(verify: "let a: Power = sut.db.mem.max();"),
        "expected Power, got Percentage"
      )

      assert_error(
        with_machines(verify: "assert sut.both.power.max() < 5%;"),
        "< cannot be used on Power and Percentage"
      )
    end

    test "readings are mean or max, and are not values" do
      assert_error(
        with_machines(verify: "let a = sut.db.mem.min();"),
        "mem is read with .mean() or .max() (C109)"
      )

      assert_error(
        with_machines(verify: "let a = sut.db.mem;"),
        "mem is not a value; use mem.mean() or mem.max()"
      )

      assert_error(with_machines(verify: "let a = sut.mem;"), "sut.mem is read with .mean() or .max() (C109)")
    end

    test "readings follow the phase rules (C146)" do
      assert_error(with_machines(actions: "let a = sut.db.mem.max();"), "metrics cannot be read in Actions")
    end

    test "the load generator is read without configuration (C160)" do
      assert errors(
               "TestSuite S { Load { } Test T { Actions { } Verify { assert loadGenerator.cpu.max() < 5%; assert loadGenerator.mem.max() < 5%; } } }"
             ) == []

      assert_error(
        errors(
          "TestSuite S { Load { } Test T { Actions { } Verify { assert loadGenerator.gpu.max() < 5%; } } }"
        ),
        "loadGenerator reads only cpu and mem (C160)"
      )
    end

    test "through a Target value a reading is left to run time" do
      assert with_machines(verify: "let t = sut.web; assert t.cpu.max() < 5%;") == []
    end

    test "energy, power and carbon need a target that lists power (C161)" do
      assert with_machines(verify: "assert energy.total() < 1J; assert power.mean() < 1W;") == []

      source = "TestSuite S { Load { } Test T { Actions { } Verify { assert energy.total() < 1J; } } }"
      assert_error(errors(source), "energy metrics need a target with power in its metrics (C161)")

      source = "TestSuite S { Load { } Test T { Actions { } Verify { assert power.mean() < 1W; } } }"
      assert_error(errors(source), "power metrics need a target with power in its metrics")
    end

    test "carbon also needs carbonIntensity (C161)" do
      assert_error(
        with_machines(verify: "assert carbon.total() < 1gCO2e;"),
        "carbon metrics need carbonIntensity in monitoring (C161)"
      )

      file =
        ~s|Config { sut { a { host = "h"; metrics = [power]; } } monitoring { port = 1; format = prometheus; fields { power = "p"; } carbonIntensity = 380gCO2e/kWh; } }|

      assert errors(
               "TestSuite S { Load { } Test T { Actions { } Verify { assert carbon.total() < 1gCO2e; } } }",
               file
             ) == []
    end

    test "a measured target needs a format and a port (C158)" do
      source = "TestSuite S { Load { } Test T { Actions { } } }"
      assert errors(source, ~s|Config { sut { a { host = "h"; } } }|) == []

      assert_error(
        errors(source, ~s|Config { sut { a { host = "h"; metrics = [cpu]; } } }|),
        "target a lists metrics from an agent, so monitoring needs a format (C158)"
      )

      assert_error(
        errors(
          source,
          ~s|Config { sut { a { host = "h"; metrics = [cpu]; } } monitoring { format = prometheus; } }|
        ),
        "target a lists metrics from an agent, so monitoring needs a port, or the target a metricsPort (C158)"
      )

      assert errors(
               source,
               ~s|Config { sut { a { host = "h"; metrics = [cpu]; metricsPort = 9400; } } monitoring { format = prometheus; } }|
             ) == []
    end

    test "prometheus computes cpu, mem and disk; the rest need a field (C158)" do
      source = "TestSuite S { Load { } Test T { Actions { } } }"

      config = fn metrics, settings ->
        ~s|Config { sut { a { host = "h"; metrics = [#{metrics}]; } } monitoring { port = 1; #{settings} } }|
      end

      assert errors(source, config.("cpu, mem, disk", "format = prometheus;")) == []
      assert errors(source, config.("gpu", ~s|format = prometheus; fields { gpu = "g"; }|)) == []

      assert_error(
        errors(source, config.("gpu", "format = prometheus;")),
        "target a reads gpu from an agent, so monitoring needs a field for it (C158)"
      )

      assert_error(
        errors(source, config.("power", "format = prometheus;")),
        "target a reads power from an agent"
      )
    end

    test "the aetherion agent needs no port, and measures cpu, mem, disk and net (C185)" do
      source = "TestSuite S { Load { } Test T { Actions { } } }"

      config = fn target, monitoring ->
        ~s|Config { sut { a { #{target} } } monitoring { format = aetherion; #{monitoring} } }|
      end

      assert errors(source, config.(~s|host = "h"; metrics = [cpu[0], mem, disk["sda"], net["eth0"]];|, "")) ==
               []

      assert errors(source, config.(~s|baseUrl = "http://h:8080"; metrics = [cpu];|, "")) == []

      # A metric with a topic comes over MQTT; the agent does not read it.
      assert errors(
               source,
               config.(
                 ~s|host = "h"; metrics = [cpu, power]; topics { power = "p"; }|,
                 ~s|mqtt { broker = "mqtt://b"; }|
               )
             ) == []

      assert_error(
        errors(source, config.(~s|host = "h"; metrics = [cpu, gpu];|, "")),
        "the aetherion agent measures cpu, mem, disk and net, not gpu; give gpu a topic (C163), " <>
          "or read target a with format prometheus or json (C185)"
      )

      assert_error(
        errors(source, config.(~s|host = "h"; metrics = [power];|, "")),
        "not power; give power a topic"
      )

      assert_error(
        errors(source, config.(~s|host = "h"; metrics = [cpu]; metricsPort = 9100;|, "")),
        "metricsPort is for an agent over HTTP; with format = aetherion the agent of a is the node a@<host> (C185)"
      )

      for setting <- ["port = 9100;", ~s|path = "/m";|, ~s|fields { cpu = "c"; }|] do
        [name | _] = String.split(setting, " ")

        assert_error(
          errors(source, config.(~s|host = "h"; metrics = [cpu];|, setting)),
          "#{name} is for an agent over HTTP; with format = aetherion each agent is the node <target>@<host> (C185)"
        )
      end

      assert_error(
        errors(source, config.(~s|host = "me@h"; metrics = [cpu];|, "")),
        "the host of target a cannot hold @; its agent is a@<host> (C185)"
      )
    end

    test "an aetherion agent and a worker are separate nodes (C181, C185)" do
      source = "TestSuite S { Load { } Test T { Actions { } } }"

      assert_error(
        errors(
          source,
          ~s|Config { sut { w1 { host = "10.0.0.1"; metrics = [cpu]; } } monitoring { format = aetherion; } workers { w1 { host = "10.0.0.1"; } } }|
        ),
        "target w1 and the worker w1 are both the node w1@10.0.0.1"
      )

      assert errors(
               source,
               ~s|Config { sut { a1 { host = "10.0.0.1"; metrics = [cpu]; } } monitoring { format = aetherion; } workers { w1 { host = "10.0.0.1"; } } }|
             ) == []
    end

    test "net is a DataRate (C186)" do
      config = ~s|Config { sut { a { host = "h"; metrics = [net]; } } monitoring { format = aetherion; } }|
      verify = fn statement -> "TestSuite S { Load { } Test T { Actions { } Verify { #{statement} } } }" end

      assert errors(verify.("assert sut.a.net.max() < 100MB/s; assert sut.net.mean() >= 0B/s;"), config) == []
      assert_error(errors(verify.("assert sut.a.net.max() < 50%;"), config), "DataRate and Percentage")
    end

    test "json needs a field for every agent metric (C158)" do
      source = "TestSuite S { Load { } Test T { Actions { } } }"

      with_field =
        ~s|Config { sut { a { host = "h"; metrics = [cpu]; } } monitoring { port = 1; format = json; fields { cpu = "cpu.total"; } } }|

      assert errors(source, with_field) == []

      without =
        ~s|Config { sut { a { host = "h"; metrics = [cpu]; } } monitoring { port = 1; format = json; } }|

      assert_error(
        errors(source, without),
        "target a reads cpu from an agent, so monitoring needs a field for it"
      )
    end

    test "a metric from a topic needs no agent field (C163)" do
      source = "TestSuite S { Load { } Test T { Actions { } } }"

      file =
        ~s|Config { sut { a { host = "h"; metrics = [cpu, power]; topics { power = "t"; } } } monitoring { port = 1; format = prometheus; mqtt { broker = "mqtt://b"; } } }|

      assert errors(source, file) == []
    end

    test "a metric with a topic needs mqtt, not an agent (C163)" do
      source = "TestSuite S { Load { } Test T { Actions { } Verify { assert sut.a.power.mean() < 1W; } } }"
      mqtt = ~s|monitoring { mqtt { broker = "mqtt://b"; } }|

      assert errors(source, ~s|Config { sut { a { metrics = [power]; topics { power = "t"; } } } #{mqtt} }|) ==
               []

      assert_error(
        errors(source, ~s|Config { sut { a { metrics = [power]; topics { power = "t"; } } } }|),
        "target a has topics, so monitoring needs mqtt (C163)"
      )
    end

    test "agent metrics next to a topic still need a format and a port (C158, C163)" do
      source = "TestSuite S { Load { } Test T { Actions { } } }"

      file =
        ~s|Config { sut { a { host = "h"; metrics = [cpu, power]; topics { power = "t"; } } } monitoring { mqtt { broker = "mqtt://b"; } } }|

      assert_error(errors(source, file), "target a lists metrics from an agent, so monitoring needs a format")

      file =
        ~s|Config { sut { a { host = "h"; metrics = [cpu, power]; topics { power = "t"; } } } monitoring { port = 9100; format = prometheus; mqtt { broker = "mqtt://b"; } } }|

      assert errors(source, file) == []
    end

    test "energy works from a topic (C161, C163)" do
      source = "TestSuite S { Load { } Test T { Actions { } Verify { assert energy.total() < 1J; } } }"

      file =
        ~s|Config { sut { a { metrics = [power]; topics { power = "t"; } } } monitoring { mqtt { broker = "mqtt://b"; } } }|

      assert errors(source, file) == []
    end

    test "monitoring in the file replaces the suite's as a whole (C157)" do
      source = """
      TestSuite S {
        Config {
          sut { a { host = "h"; metrics = [cpu]; } }
          monitoring { port = 1; format = prometheus; carbonIntensity = 1gCO2e/kWh; }
        }
        Load { }
        Test T { Actions { } }
      }
      """

      assert errors(source) == []
      assert_error(errors(source, "Config { monitoring { port = 2; } }"), "monitoring needs a format")

      {:ok, ast} =
        Analyzer.analyze(PerfLang.parse!(source),
          config: config!(~s|Config { monitoring { port = 2; format = prometheus; } }|)
        )

      assert [%AST.Monitoring{settings: [%AST.MonitorPort{}, %AST.MonitorFormat{}]}] =
               Enum.filter(ast.config.sections, &match?(%AST.Monitoring{}, &1))
    end

    test "through a Target value it is left to run time" do
      assert with_machines(actions: ~s|let t = sut.db; t.http.get("/");|) == []
    end

    test "a variable named sut is not a target" do
      assert_error(with_machines(actions: ~s|let sut = 1; sut.db.http.get("/");|), "Int has no member db")
    end
  end

  describe "sut.any (C168)" do
    @any_load "stages [ 1vu for 1s ] distribution { api 100%; }"

    test "picks a Target in Actions, with a distribution" do
      assert errors(suite(load: @any_load, actions: ~s|sut.any.http.get("/"); let t: Target = sut.any;|)) ==
               []
    end

    test "needs a distribution" do
      assert_error(actions(~s|sut.any.http.get("/");|), "sut.any needs a distribution in Load (C168)")
    end

    test "only works in Actions" do
      for {part, what} <- [
            setup: ~s|sut.any.http.get("/");|,
            verify: "let t = sut.any;",
            cleanup: "let t = sut.any;"
          ] do
        source = suite([{:load, @any_load}, {part, what}])

        assert_error(
          errors(source),
          "sut.any picks a target per iteration, so it only works in Actions (C168)"
        )
      end

      assert_error(errors(suite(load: @any_load <> " stopIf sut.any == sut.api;")), "only works in Actions")
    end

    test "a distribution in a Test's Load counts for that Test" do
      source = """
      TestSuite S {
        Config { sut { api { baseUrl = "http://h"; } } }
        Test A { Load { stages [ 1vu for 1s ] distribution { api 100%; } } Actions { sut.any.http.get("/"); } }
        Test B { Load { } Actions { sut.any.http.get("/"); } }
      }
      """

      assert [message] = errors(source)
      assert String.starts_with?(message, "4:")
      assert message =~ "sut.any needs a distribution"
    end

    test "works in a fn, where the phase is only known at run time" do
      assert errors(suite(functions: ~s|fn f(): Response { return sut.any.http.get("/"); }|)) == []
    end
  end

  describe "built-ins (C133, C144, C145)" do
    test "range" do
      assert actions_type("range(0, 3)") == {:list, :int}
      assert_error(actions("let a = range(0, 1.5);"), "expected Int, got Float")
      assert_error(actions("let a = range(1);"), "expected 2 arguments, got 1")
    end

    test "sleep takes a Time" do
      assert actions("let p = 5s; sleep(p); sleep(p * 2);") == []
      assert_error(actions("let p = 5; sleep(p);"), "expected Time, got Int")
    end

    test "math works in every expression" do
      assert actions_type("sqrt(2)") == :float
      assert actions_type("pi * 2") == :float
      assert actions_type("e") == :float
      assert_error(actions(~s|let a = sqrt("x");|), "expected Float, got String")
    end

    test "min and max take numbers or one unit type" do
      assert actions_type("min(1, 2)") == :int
      assert actions_type("max(1, 2.5)") == :float
      assert actions_type("min(1s, 2s)") == :time
      assert actions_type("max(1%, 2%)") == :percentage

      assert_error(
        actions("let a = min(1s, 2);"),
        "min takes two numbers or two values of one unit type (C144)"
      )

      assert_error(actions("let a = max(1);"), "max takes 2 arguments, got 1 (C144)")
    end

    test "list methods" do
      assert actions_type("[1].length()") == :int
      assert actions_type("[1].contains(1)") == :bool
      assert actions_type("[1].random()") == :int
      assert actions_type("[1].random(2)") == {:list, :int}
      assert actions_type("{ \"a\": 1 }[\"a\"].random(2)") == {:list, :json}
    end

    test "list method arguments" do
      assert_error(actions("let a = [1].length(1);"), "length takes no arguments, got 1")
      assert_error(actions("let a = [1].contains();"), "contains takes 1 argument, got 0")
      assert_error(actions(~s|let a = [1].contains("x");|), "expected Int, got String")
      assert_error(actions("let a = [1].random(1.5);"), "expected Int, got Float")
    end

    test "unknown methods and names" do
      assert_error(actions("let a = [1].foo();"), "List<Int> has no method foo")
      assert_error(actions("let a = 1; a.length();"), "Int has no method length")
      assert_error(actions("foo();"), "unknown name foo")
      assert_error(actions("let a = 1; a();"), "Int is not a function")
    end

    test "+ on strings" do
      assert actions_type(~s|"a" + "b"|) == :string
      assert actions_type(~s|"a" + {}["id"]|) == :string
      assert_error(actions(~s|let a = "a" + 1;|), "+ cannot be used on String and Int")
    end
  end

  describe "toString (C177)" do
    test "gives a String for every value with a text form" do
      for value <- ~w(1 1.5 true "a" 5s 10J 2W 3gCO2e 70% 50vu) do
        assert actions_type("(#{value}).toString()") == :string, value
      end

      assert actions_type(~s|{ "id": 1 }["id"].toString()|) == :string
      assert actions_type("range(0, 3).random().toString()") == :string
      assert actions(~s|let user = "username_" + range(0, 10).random().toString();|) == []
    end

    test "works on metrics in Verify" do
      assert errors(suite(verify: ~s|check ("p95=" + latency.p95().toString()) != "";|)) == []
    end

    test "toString stays usable as a name" do
      assert actions("let toString = 1; let a = toString.toString();") == []
    end

    test "rejects values without a text form and arguments" do
      assert_error(actions("let a = [1].toString();"), "List<Int> has no method toString (C177)")

      assert_error(
        actions(~s|let r = sut.api.http.get("/"); let a = r.toString();|),
        "Response has no method toString (C177)"
      )

      assert_error(actions("let a = sut.api.toString();"), "Target has no method toString (C177)")
      assert_error(actions("let n = 1; let a = n.toString(2);"), "toString takes no arguments, got 1 (C177)")
      assert_error(actions("let a = toString(1);"), "unknown name toString")
    end
  end

  describe "metrics (C60, C109, C146, C154)" do
    test "metric types" do
      verify = """
      let a: Time = latency.p95();
      let b: Float = throughput.perSecond();
      let c: Percentage = errors.rate();
      let d: Int = errors.count();
      let e: Energy = energy.total();
      let f: Power = power.mean();
      let g: Carbon = carbon.total();
      let h: Percentage = sut.api.cpu.max();
      assert throughput.perSecond() > 100;
      assert errors.count() == 0;
      """

      assert errors(suite(verify: verify)) == []
    end

    test "both sides of a comparison have one type (C59)" do
      assert_error(verify("assert latency.p95() > 10J;"), "> cannot be used on Time and Energy (C153)")
      assert_error(verify("assert errors.rate() < 2;"), "< cannot be used on Percentage and Int (C153)")
    end

    test "read in Verify, stopIf and Cleanup" do
      assert errors(suite(verify: "assert errors.rate() < 1%;", cleanup: "assert errors.rate() < 1%;")) == []
      assert errors(suite(load: "stopIf errors.rate() > 1%; stopIf sut.cpu.max() > 90%;")) == []
    end

    test "rejected in Setup and Actions" do
      assert_error(errors(suite(setup: "let a = errors.rate();")), "metrics cannot be read in Setup")
      assert_error(actions("let a = errors.rate();"), "metrics cannot be read in Actions")
      assert_error(actions("let a = sut.api.cpu.max();"), "metrics cannot be read in Actions")
      assert_error(actions("let a = sut.cpu.max();"), "metrics cannot be read in Actions")
      assert_error(actions("let a = loadGenerator.cpu.max();"), "metrics cannot be read in Actions")
    end

    test "through a fn, directly or not" do
      functions = """
      fn low(): Bool { return errors.rate() < 1%; }
      fn wrapper(): Bool { return low(); }
      fn plain(): Int { return 1; }
      """

      assert errors(suite(functions: functions, verify: "assert wrapper();", actions: "let a = plain();")) ==
               []

      assert_error(
        errors(suite(functions: functions, actions: "let a = wrapper();")),
        "fn wrapper reads metrics"
      )

      assert_error(errors(suite(functions: functions, setup: "let a = low();")), "fn low reads metrics")

      assert_error(
        errors(suite(functions: functions, actions: "let a = [1].map(\\x -> low());")),
        "fn low reads metrics"
      )
    end

    test "cpu is read with mean or max" do
      assert_error(verify("let a = sut.api.cpu.min();"), "cpu is read with .mean() or .max()")
      assert_error(verify("let a = sut.cpu;"), "sut.cpu is read with .mean() or .max()")
    end

    test "percentile from 0 to 100" do
      assert verify("assert latency.percentile(0) < 1s; assert latency.percentile(100) < 1s;") == []

      assert_error(
        verify("assert latency.percentile(100.5) < 1s;"),
        "percentile takes a number from 0 to 100, got 100.5 (C154)"
      )
    end
  end

  describe "request metrics per target (C176)" do
    test "every measurement of latency, throughput and errors, with its type" do
      verify = """
      let a: Time = sut.api.latency.p95();
      let b: Time = sut.api.latency.percentile(99.9);
      let c: Float = sut.api.throughput.perSecond();
      let d: Percentage = sut.api.errors.rate();
      let e: Int = sut.api.errors.connectionErrors();
      assert sut.api.latency.p50() < 300ms;
      assert sut.api.errors.count() == 0;
      """

      assert verify(verify) == []
    end

    test "the parser's call becomes a Metric with its target" do
      source = suite(verify: "let x = sut.api.latency.p95();")

      %AST.TestSuite{tests: [%AST.Test{verify: %AST.Phase{statements: [%AST.Let{value: value}]}}]} =
        analyzed!(source)

      assert %AST.Metric{group: :latency, measurement: :p95, type: :time, target: %AST.Member{name: "api"}} =
               value
    end

    test "through a Target value, in Verify, Cleanup and a fn" do
      verify = "for region in [sut.api] { assert region.errors.rate() < 1%; }"
      functions = "fn fast(t: Target): Bool { return t.latency.p95() < 300ms; }"

      assert errors(suite(verify: verify, cleanup: "let a = sut.api.errors.count();")) == []
      assert errors(suite(functions: functions, verify: "assert fast(sut.api);")) == []
    end

    test "not in Setup, Actions or stopIf" do
      assert_error(errors(suite(setup: "let a = sut.api.errors.rate();")), "metrics cannot be read in Setup")
      assert_error(actions("let a = sut.api.latency.p95();"), "metrics cannot be read in Actions")

      assert_error(
        errors(suite(load: "stopIf sut.api.errors.rate() > 1%;")),
        "stopIf reads live totals, so it cannot read a metric per target (C58, C176)"
      )
    end

    test "the measurement is one of C60" do
      assert_error(
        verify("let a = sut.api.latency.p42();"),
        "latency has no measurement p42; use p50, p90, p95, p99, mean, min, max, percentile (C60)"
      )

      assert_error(verify("let a = sut.api.errors.total();"), "errors has no measurement total")
      assert_error(verify("let a = sut.api.latency.p95(1);"), "p95() takes no arguments (C60)")
      assert_error(verify("let a = sut.api.latency.percentile();"), "percentile takes one number")

      assert_error(
        verify("assert sut.api.latency.percentile(100.5) < 1s;"),
        "percentile takes a number from 0 to 100, got 100.5 (C154)"
      )
    end

    test "over all targets it is written without sut" do
      assert_error(
        verify("let a = sut.latency.p95();"),
        "latency.p95() is already over all targets, without sut (C176)"
      )
    end

    test "the target takes requests" do
      assert with_machines(verify: "assert sut.web.errors.rate() < 1%;") == []

      assert_error(
        with_machines(verify: "assert sut.db.errors.rate() < 1%;"),
        "a request metric per target needs a target with a baseUrl, and db has none (C156)"
      )

      assert_error(verify("let a = sut.nowhere.latency.p95();"), "unknown target nowhere")
    end

    test "latency of a Response stays its field" do
      assert actions(~s|let r = sut.api.http.get("/"); let t: Time = r.latency;|) == []
      assert verify("let a = sut.api.latency.p95();") == []
      assert actions(~s|let r = sut.api.http.get("/"); let t = r.latency.p95();|) != []
    end
  end

  describe "operators (C147, C153)" do
    test "! and unary -" do
      assert actions_type("!true") == :bool
      assert actions_type("-5s") == :time
      assert actions_type("-1.5") == :float
      assert_error(actions("let a = !1;"), "expected Bool, got Int")
      assert_error(actions(~s|let a = -"x";|), "unary - needs a number or a unit value, got String (C147)")
      assert_error(actions("let a = -5%;"), "unary - needs a number or a unit value, got Percentage")
    end

    test "== on one type, by value" do
      assert actions("assert 1000ms == 1s; assert 1 == 1.5; assert sut.api == sut.api; assert [1] == [2];") ==
               []

      assert_error(actions(~s|assert 1 == "a";|), "== cannot be used on Int and String (C153)")
      assert_error(actions("assert 5s != 5J;"), "!= cannot be used on Time and Energy (C153)")
    end

    test "ordering takes numbers and units" do
      assert actions("assert 1 < 1.5; assert 1s < 2s; assert 1% < 2%; assert 1vu < 2vu; assert 1J < 2J;") ==
               []

      assert_error(actions(~s|assert "a" < "b";|), "< cannot be used on String and String (C153)")
      assert_error(actions("assert true < false;"), "< cannot be used on Bool and Bool (C153)")
      assert_error(actions("assert 5vu < 5;"), "< cannot be used on VirtualUsers and Int (C153)")
    end

    test "&& and || take Bool" do
      assert_error(actions("assert 1 && true;"), "expected Bool, got Int")
      assert_error(actions("assert true || 1;"), "expected Bool, got Int")
    end
  end

  describe "match (C75, C148)" do
    test "a value match gives one type" do
      assert actions(~s|let a = match 1 { 1 => "x", _ => "y" };|) == []
      assert actions_type(~s|match 1 { 1 => 1, _ => 2.5 }|) == :float

      assert_error(
        actions(~s|let a = match 1 { 1 => "x", _ => 2 };|),
        "all arms of a match used as a value must give one type, got String and Int (C148)"
      )

      assert_error(actions(~s|let a = match 1 { 1 => { }, _ => 2 };|), "must give one type, got Unit and Int")
    end

    test "a value match covers every case" do
      assert actions("let a = match 1 { 1 => 1, n => n };") == []
      assert actions("let a = match true { true => 1, false => 2 };") == []
      assert_error(actions("let a = match 1 { 1 => 1 };"), "must cover every case")
      assert_error(actions("let a = match 1 { 1 => 1, n if n > 1 => 2 };"), "must cover every case")
      assert_error(actions("let a = match 1 { 1 => 1, _ if false => 2 };"), "must cover every case")
      assert_error(actions("let a = match true { true => 1 };"), "must cover every case")
      assert_error(actions("let a = match true { true if false => 1, false => 2 };"), "must cover every case")
    end

    test "a statement match has neither rule" do
      assert actions(~s|match 1 { 1 => "x", 2 => 2 }|) == []
      assert actions(~s|match 1 { 1 => { }, 2 => ({ "ok": true }) }|) == []
    end

    test "patterns have the type of the matched value" do
      assert actions(~s|let a = match {}["x"] { 1 => 1, "s" => 2, _ => 3 };|) == []

      assert_error(
        actions(~s|match 1 { "a" => 1 }|),
        "a pattern of type String cannot match a value of type Int (C148)"
      )

      assert_error(
        actions(~s|match 5s { 5 => 1 }|),
        "a pattern of type Int cannot match a value of type Time"
      )
    end

    test "bindings and guards" do
      assert actions("let a = match 1 { n if n > 0 => n, _ => 0 };") == []
      assert_error(actions("let a = match 1 { n if n => 1, _ => 0 };"), "expected Bool, got Int")
      assert_error(actions("match 1 { n => 1 } let b = n;"), "unknown name n")
    end
  end

  describe "functions (C71, C150)" do
    test "use before declaration and mutual recursion" do
      functions = """
      fn even(n: Int): Bool { if n == 0 { return true; } else { return odd(n - 1); } }
      fn odd(n: Int): Bool { if n == 0 { return false; } else { return even(n - 1); } }
      """

      assert errors(suite(functions: functions)) == []
    end

    test "a non-Unit fn returns on every path" do
      assert_error(errors(suite(functions: "fn f(): Int { }")), "fn f must return Int on every path (C150)")
      assert_error(errors(suite(functions: "fn f(a: Bool): Int { if a { return 1; } }")), "must return Int")

      assert_error(
        errors(suite(functions: "fn f(a: Bool): Int { while a { return 1; } }")),
        "must return Int"
      )

      assert_error(errors(suite(functions: "fn f(): Int { for i in [1] { return 1; } }")), "must return Int")
    end

    test "paths through if and match" do
      assert errors(
               suite(
                 functions:
                   "fn f(a: Bool): Int { if a { return 1; } else if !a { return 2; } else { return 3; } }"
               )
             ) == []

      assert errors(
               suite(functions: "fn f(a: Int): Int { match a { 1 => { return 1; }, _ => { return 2; } } }")
             ) == []

      assert_error(
        errors(suite(functions: "fn f(a: Int): Int { match a { 1 => { return 1; } } }")),
        "must return Int"
      )

      assert_error(
        errors(suite(functions: "fn f(a: Int): Int { match a { 1 => { return 1; }, _ => 2 } }")),
        "must return Int"
      )

      assert errors(suite(functions: "fn f(): Unit { }")) == []
    end

    test "return types" do
      assert_error(errors(suite(functions: ~s|fn f(): Int { return "a"; }|)), "expected Int, got String")
      assert_error(errors(suite(functions: "fn f(): Int { return; }")), "return needs a value of type Int")
      assert_error(errors(suite(functions: "fn f(): Unit { return 1; }")), "expected Unit, got Int")
      assert errors(suite(functions: "fn f(): Unit { return; }")) == []
    end

    test "arguments" do
      functions = "fn f(a: Int, b: Float): Int { return a; }"
      assert errors(suite(functions: functions, actions: "let a: Int = f(1, 2);")) == []
      assert_error(errors(suite(functions: functions, actions: "f(1);")), "expected 2 arguments, got 1")
      assert_error(errors(suite(functions: functions, actions: ~s|f("a", 1);|)), "expected Int, got String")
      assert_error(actions("let a = sqrt(1, 2);"), "expected 1 argument, got 2")
    end

    test "parameters are not mutable" do
      assert_error(errors(suite(functions: "fn f(a: Int): Unit { a = 1; }")), "a is not mutable")
    end
  end

  describe "lambdas (C90, C151)" do
    test "types come from context" do
      assert actions_type("[1].map(\\x -> x + 1)") == {:list, :int}
      assert actions_type("[1].filter(\\x -> x > 0)") == {:list, :int}
      assert actions_type("[1].fold(0, \\(sum, x) -> sum + x)") == :int
      assert actions_type("[1].foldr(0, \\(x, sum) -> x + sum)") == :int
      assert actions("let f: Fn<Int, Bool> = \\x -> x > 0; let a: Bool = f(1);") == []
    end

    test "without context they must be written" do
      assert_error(actions("let f = \\x -> x;"), "lambda parameter x needs a type here")
      assert actions("let f = \\(x: Int) -> x;") == []
    end

    test "written types must fit the context" do
      assert actions("[1].map(\\(x: Int) -> x);") == []
      assert_error(actions(~s|["a"].map(\\(x: Int) -> x);|), "lambda parameter x is Int, expected String")
    end

    test "arity and return types" do
      assert_error(actions("[1].map(\\(a, b) -> a);"), "this lambda takes 2 parameters, expected 1")
      assert_error(actions("[1].filter(\\x -> x);"), "expected Bool, got Int")
      assert_error(actions("let f: Fn<Int, Bool> = \\x -> x;"), "expected Bool, got Int")
    end

    test "the last Fn type is the return type" do
      assert actions("let f: Fn<Int, String, Bool> = \\(a, b) -> a > 0; let c: Bool = f(1, \"s\");") == []
    end

    test "a lambda reads the variables around it" do
      assert actions("let limit = 1; let a = [1].filter(\\x -> x > limit);") == []
    end

    test "named functions as values" do
      functions = "fn ok(a: Int): Bool { return a > 0; }"

      assert errors(suite(functions: functions, actions: "let a = [1].map(ok); let b = [1].filter(ok);")) ==
               []

      assert errors(suite(functions: functions, actions: ~s|let a = {}["x"].map(ok);|)) == []

      assert_error(
        errors(suite(functions: functions, actions: ~s|let a = ["s"].map(ok);|)),
        "expected Fn<String, Bool>, got Fn<Int, Bool>"
      )

      assert_error(errors(suite(actions: "let n = 1; let a = [1].map(n);")), "got Int")
    end

    test "functions in functions" do
      functions = """
      fn apply(f: Fn<Int, Int>, a: Int): Int { return f(a); }
      """

      assert errors(suite(functions: functions, actions: "let a = apply(\\x -> x + 1, 1);")) == []

      assert_error(
        errors(suite(functions: functions, actions: "let a = apply(\\x -> x > 0, 1);")),
        "expected Int, got Bool"
      )
    end
  end

  describe "curves and stopIf (C25, C28, C56, C152)" do
    test "stages use curves with their arguments" do
      load = "curves { wave(t, n) = t + sin(n * t); up(t) = t^2; } stages [ 1vu in 1s wave(3), 2vu in 1s up ]"
      assert errors(suite(load: load)) == []
      assert errors(suite(load: "stages [ 1vu in 1s exp, 2vu in 1s linear, 3vu in 1s min(0.5) ]")) == []
    end

    test "unknown curves and wrong arguments" do
      assert_error(errors(suite(load: "stages [ 1vu in 1s foo ]")), "unknown curve foo (C25)")
      assert_error(errors(suite(load: "stages [ 1vu in 1s pi ]")), "unknown curve pi")

      load = "curves { wave(t, n) = t; } stages [ 1vu in 1s wave ]"
      assert_error(errors(suite(load: load)), "curve wave takes 1 argument after the time, got 0 (C28)")

      assert_error(
        errors(suite(load: "stages [ 1vu in 1s exp(3) ]")),
        "curve exp takes 0 arguments after the time, got 1"
      )

      assert_error(errors(suite(load: "stages [ 1vu in 1s exp(\"a\") ]")), "expected Float, got String")
    end

    test "a curve needs the time" do
      assert_error(
        errors(suite(load: "curves { flat() = 1; }")),
        "curve flat needs a parameter for the time (C28)"
      )
    end

    test "curves give numbers" do
      assert_error(errors(suite(load: "curves { c(t) = t > 0; }")), "expected Float, got Bool")
    end

    test "curves call curves, but not in a cycle" do
      assert errors(suite(load: "curves { a(t) = b(t) + 1; b(t) = t; }")) == []

      assert_error(
        errors(suite(load: "curves { a(t) = a(t); }")),
        "curve a calls itself, directly or through another curve (C56)"
      )

      found = errors(suite(load: "curves { a(t) = b(t); b(t) = c(t); c(t) = a(t); }"))
      assert_error(found, "curve a calls itself")
      assert_error(found, "curve b calls itself")
      assert_error(found, "curve c calls itself")
    end

    test "curves see parameters, curves and math" do
      assert_error(errors(suite(load: "curves { c(t) = x; }")), "unknown name x")
      assert_error(errors(suite(load: "curves { c(t) = sut.api; }")), "unknown name sut")

      assert_error(
        errors(suite(load: "curves { c(t) = errors.count(); }")),
        "a curve cannot read metrics (C152)"
      )

      assert_error(
        errors(suite(load: "curves { c(t) = http.get(\"http://h\"); }")),
        "a curve cannot make http calls (C152)"
      )

      assert_error(errors(suite(load: "curves { c(t) = sleep(1s); }")), "a curve cannot call sleep")

      assert_error(
        errors(suite(functions: "fn f(): Int { return 1; }", load: "curves { c(t) = f(); }")),
        "a curve cannot call fn f (C152)"
      )
    end

    test "stopIf needs a Bool" do
      assert_error(errors(suite(load: "stopIf errors.count();")), "expected Bool, got Int")
    end

    test "stopIf sees metrics and built-ins" do
      assert errors(suite(load: "stopIf max(latency.p50(), latency.p95()) > 2s;")) == []
      assert_error(errors(suite(load: "stopIf x > 1;")), "unknown name x")

      assert_error(
        errors(suite(load: ~s|stopIf sut.api.http.get("/").status == 500;|)),
        "stopIf cannot make http calls (C152)"
      )

      assert_error(
        errors(suite(functions: "fn f(): Bool { return true; }", load: "stopIf f();")),
        "stopIf cannot call fn f (C152)"
      )
    end

    test "a Load in each Test is checked too" do
      source = """
      TestSuite S {
        Test T { Load { stopIf x; } Actions { } }
      }
      """

      assert_error(errors(source), "unknown name x")
    end
  end

  describe "robustness" do
    test "one wrong name gives one error, not a cascade" do
      assert actions("let a = b; let c = a + 1; assert c > 0; a.foo(); let d = a[0];") == [
               "15:23: unknown name b"
             ]
    end

    test "unknown callees still check their arguments" do
      found = actions("foo(bar);")
      assert_error(found, "unknown name bar")
      assert_error(found, "unknown name foo")
    end

    test "a type nobody filled in stays quiet" do
      assert actions("let a = [[]]; let b = a[0][0]; b.foo(); let c = b.bar; let d = b + 1;") == []
    end

    test "a suite without optional blocks" do
      source = "TestSuite S { Test T { Load { } Actions { } } }"
      assert errors(source) == []
      assert %AST.TestSuite{functions: nil, config: nil} = analyzed!(source)
    end
  end

  describe "load generators on workers (C181, C183)" do
    defp workers_suite(config, verify) do
      """
      TestSuite S {
        Config { #{config} }
        Load { }
        Test T { Actions { } Verify { #{verify} } }
      }
      """
    end

    @workers ~s|workers { euWorker1 { host = "10.0.0.11"; } usWorker { host = "10.1.0.11"; } }|

    test "loadGenerator.<worker> reads one worker, loadGenerator all of them" do
      verify = """
      assert loadGenerator.euWorker1.cpu.max() < 70%;
      assert loadGenerator.usWorker.mem.mean() < 80%;
      assert loadGenerator.cpu.mean() < 50%;
      """

      assert errors(workers_suite(@workers, verify)) == []
    end

    test "the worker must be defined, and reads only cpu and mem" do
      assert [message] = errors(workers_suite(@workers, "assert loadGenerator.nobody.cpu.max() < 70%;"))

      assert message =~
               "unknown worker nobody; define it in Config { workers { ... } } or pass it with --workers (C183)"

      assert [message] = errors(workers_suite("", "assert loadGenerator.euWorker1.cpu.max() < 70%;"))
      assert message =~ "unknown worker euWorker1"

      assert [message] = errors(workers_suite(@workers, "assert loadGenerator.euWorker1.gpu.max() < 70%;"))
      assert message =~ "loadGenerator.euWorker1 reads only cpu and mem (C160, C183)"

      assert [message] = errors(workers_suite(@workers, "let w = loadGenerator.euWorker1;"))
      assert message =~ "loadGenerator is not a value"
    end

    test "the workers of an external configuration file replace the suite's (C157, C181)" do
      suite =
        workers_suite(
          ~s|workers { old { host = "10.9.9.9"; } }|,
          "assert loadGenerator.euWorker1.cpu.max() < 70%;"
        )

      assert errors(suite, "Config { #{@workers} }") == []

      suite =
        workers_suite(~s|workers { old { host = "10.9.9.9"; } }|, "assert loadGenerator.old.cpu.max() < 70%;")

      assert [message] = errors(suite, "Config { #{@workers} }")
      assert message =~ "unknown worker old"
    end
  end
end
