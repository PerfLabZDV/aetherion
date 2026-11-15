defmodule PerfLang.Validator do
  @moduledoc """
  Structural checks the grammar defers ("checked after parsing").

      {:ok, ast} = PerfLang.Validator.validate(ast)
      {:error, [%PerfLang.Error{stage: :validator}, ...]} = PerfLang.Validator.validate(bad_ast)
      {:ok, config} = PerfLang.Validator.validate(external_config)

  Runs after the parser and before the Semantic Analyzer. It collects every
  error instead of stopping at the first, and returns them sorted by position.
  There are no warnings. An external configuration file (C157) gets the
  Config checks, and holds only the sut, monitoring and workers sections, so
  neither output nor runs (C157, C178, C181). The checks:

    * Config: each section at most once (C98), each sut target once and
      none named cpu (C100, C109), each target setting at most once, and
      baseUrl an http:// or https:// URL with a host and no trailing "/"
      (C99), host without scheme, path or spaces (C156), metrics and
      metricsPort valid for the target (C159), and monitoring settings at
      most once, each in range (C158, C161). output: each setting at most once and summary a .json file;
      requests needs a .jsonl file, and fields lists known fields, at
      least one, each once (C119-C122). runs: each setting at most once,
      count at least 1 and discard below count (C178). workers: each name
      once and none named cpu, mem, disk, gpu or power, and each worker with
      exactly one host, without @ (C181, C183).
    * Load placement: in the suite or in every Test, not both (C10, C11).
      The grammar already enforces this; the check covers hand-built trees.
    * Load settings at most once each, except stopIf (C61, C78).
    * warmup and distribution only with stages, since without stages Load
      runs one iteration with one virtual user (C124).
    * retry entries at most once each (C85).
    * requestTimeout greater than 0 (C96).
    * Iteration counts in stages greater than 0 (C102), and a count per user
      (iter/vu) only in a for stage (C175).
    * A now stage is not the last stage (C127).
    * distribution: each target once, each value at most 100%, and a total
      of exactly 100%, compared in hundredths (C36, C87).
    * Time literals: parts after the first are capped (minutes and seconds
      below 60, milliseconds below 1000), and only the last part may have
      decimals (C31, C80, C81).
    * http calls (C112-C115, C123): a known method, the right number of
      arguments, a full http(s) URL for standalone http and a path
      starting with "/" for a target (when written as a string), an
      options object with only "headers" and "query", each once and each
      a JSON object (when written as literals), a body that is not a unit
      literal such as 5s (C123), and http used only as http.<method>(...).
    * sleep (C133): one argument, not negative, a Time when written as a
      literal, and no function named sleep.
    * random (C134): at most one argument.
    * A bare expression statement must be a call (C63).
    * return only inside a function (C74).
    * Naming (C46): declared names (let, fn, parameters, curves and their
      parameters, for variables, lambda parameters, match bindings) are
      camelCase; type names are PascalCase.

  Names, types and units (unknown names, curve recursion, assignment to a
  non-mut variable, Bool conditions, match coverage, targets) are left to the
  Semantic Analyzer.
  """

  alias PerfLang.{AST, Error}

  @doc "Validates a parsed suite. Returns `{:ok, ast}` or `{:error, errors}` sorted by position."
  @spec validate(%AST.TestSuite{}) :: {:ok, %AST.TestSuite{}} | {:error, [Error.t()]}
  @spec validate(%AST.Config{}) :: {:ok, %AST.Config{}} | {:error, [Error.t()]}
  def validate(%AST.TestSuite{} = ast),
    do: result(ast, load_placement(ast) ++ walk(ast, %{in_function: false}))

  def validate(%AST.Config{sections: sections} = config) do
    only_sut =
      for %{__struct__: module} = section <- sections, module in [AST.Output, AST.Runs] do
        error(
          section,
          "an external configuration file holds only the sut, monitoring and workers sections (C157, C178, C181)"
        )
      end

    result(config, only_sut ++ walk(config, %{in_function: false}))
  end

  defp result(ast, []), do: {:ok, ast}
  defp result(_ast, errors), do: {:error, Enum.sort_by(errors, &{&1.line, &1.column})}

  # ---------- Traversal ----------

  # Checks every node, then its children. The only context is whether we are
  # inside a function body, for return (C74).
  defp walk(%AST.TimePart{}, _ctx), do: []

  # http.get(...): the call checks its http, so walk skips it; any other
  # http node is an error (C112).
  defp walk(%AST.Call{callee: %AST.Member{object: %AST.Http{}}} = node, ctx),
    do: check(node, ctx) ++ walk(node.args, ctx)

  defp walk(%AST.FnDeclaration{} = node, ctx),
    do: check(node, ctx) ++ children(node, %{ctx | in_function: true})

  defp walk(%{__struct__: _} = node, ctx), do: check(node, ctx) ++ children(node, ctx)
  defp walk(list, ctx) when is_list(list), do: Enum.flat_map(list, &walk(&1, ctx))
  defp walk(_other, _ctx), do: []

  defp children(node, ctx), do: node |> Map.from_struct() |> Map.delete(:loc) |> Map.values() |> walk(ctx)

  # ---------- Load (C10, C11, C61, C78) ----------

  defp load_placement(%AST.TestSuite{load: nil, tests: tests}) do
    for %AST.Test{load: nil} = test <- tests do
      error(
        test,
        "Test #{test.name} has no Load; without a suite-level Load every Test must define one (C10)"
      )
    end
  end

  defp load_placement(%AST.TestSuite{tests: tests}) do
    for %AST.Test{load: %AST.Load{} = load} = test <- tests do
      error(load, "Test #{test.name} defines its own Load, but the suite already defines one (C11)")
    end
  end

  @unit_milliseconds %{h: 3_600_000, m: 60_000, s: 1000, ms: 1}

  @load_settings %{
    AST.Warmup => "warmup",
    AST.ThinkTime => "thinkTime",
    AST.RequestTimeout => "requestTimeout",
    AST.Curves => "curves",
    AST.Stages => "stages",
    AST.Distribution => "distribution",
    AST.Retry => "retry"
  }

  defp check(%AST.Load{settings: settings}, _ctx) do
    dups =
      settings
      |> Enum.reject(&match?(%AST.StopIf{}, &1))
      |> duplicates(&@load_settings[&1.__struct__], fn name, first ->
        "duplicate Load setting #{name} (first at #{position(first)}); only stopIf may repeat (C78)"
      end)

    dups ++ without_stages(settings) ++ warmup_length(settings)
  end

  # ---------- Config (C98-C100, C119-C121) ----------

  @config_sections %{
    AST.Sut => "sut",
    AST.Output => "output",
    AST.Monitoring => "monitoring",
    AST.Runs => "runs",
    AST.Workers => "workers"
  }

  @target_settings %{
    AST.BaseUrl => "baseUrl",
    AST.Host => "host",
    AST.TargetMetrics => "metrics",
    AST.MetricsPort => "metricsPort",
    AST.TargetTopics => "topics"
  }

  # sut.cpu reads all targets (C109), and sut.any picks one (C168), so these
  # are not target names.
  @machine_metrics ~w(cpu mem disk gpu power)

  defp check(%AST.Config{sections: sections}, _ctx) do
    duplicates(sections, &@config_sections[&1.__struct__], fn name, first ->
      "duplicate Config section #{name} (first at #{position(first)}) (C98)"
    end)
  end

  defp check(%AST.Sut{targets: targets}, _ctx) do
    dups =
      duplicates(targets, & &1.name, fn name, first ->
        "duplicate sut target #{name} (first at #{position(first)}) (C100)"
      end)

    reserved =
      for %AST.SutTarget{name: name} = target <- targets, name in @machine_metrics do
        error(target, "a sut target cannot be named #{name}; sut.#{name} reads all targets (C109)")
      end

    any =
      for %AST.SutTarget{name: "any"} = target <- targets do
        error(target, "a sut target cannot be named any; sut.any picks a target by distribution (C168)")
      end

    dups ++ reserved ++ any
  end

  # The name of a worker is the name of its node, name@host (C181), and
  # loadGenerator.cpu reads all workers (C183), so these are not worker names.
  defp check(%AST.Workers{workers: workers}, _ctx) do
    dups =
      duplicates(workers, & &1.name, fn name, first ->
        "duplicate worker #{name} (first at #{position(first)}) (C181)"
      end)

    reserved =
      for %AST.Worker{name: name} = worker <- workers, name in @machine_metrics do
        error(worker, "a worker cannot be named #{name}; loadGenerator.#{name} reads all workers (C183)")
      end

    dups ++ reserved
  end

  defp check(%AST.Worker{name: name, settings: settings} = worker, _ctx) do
    case settings do
      [] ->
        [error(worker, "worker #{name} needs a host, such as host = \"10.0.0.11\"; (C181)")]

      [%AST.Host{value: %AST.StringLiteral{value: host} = value}] ->
        if String.contains?(host, "@"),
          do: [error(value, "the host of worker #{name} cannot hold @; its node is #{name}@<host> (C181)")],
          else: []

      [_first, second | _rest] ->
        [error(second, "duplicate host in worker #{name} (C181)")]
    end
  end

  defp check(%AST.SutTarget{name: target, settings: settings} = node, _ctx) do
    dups =
      duplicates(settings, &@target_settings[&1.__struct__], fn name, first ->
        "duplicate #{name} in sut target #{target} (first at #{position(first)}) (C99)"
      end)

    dups ++ measured_target(node)
  end

  defp check(%AST.BaseUrl{value: %AST.StringLiteral{value: url} = value}, _ctx) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and host not in [nil, ""] ->
        if String.ends_with?(url, "/"),
          do: [error(value, "baseUrl #{inspect(url)} must not end with \"/\" (C99)")],
          else: []

      _ ->
        [error(value, "baseUrl #{inspect(url)} must be an http:// or https:// URL with a host (C99)")]
    end
  end

  defp check(%AST.TargetMetrics{metrics: []} = node, _ctx),
    do: [error(node, "metrics needs at least one metric; leave it out if nothing is measured (C159)")]

  defp check(%AST.TargetMetrics{metrics: metrics}, _ctx) do
    duplicates(metrics, & &1.name, fn name, first ->
      "duplicate metric #{name} (first at #{position(first)}) (C159)"
    end)
  end

  defp check(%AST.MetricSource{name: name} = node, _ctx) when name not in @machine_metrics,
    do: [error(node, "unknown metric #{name}; use #{Enum.join(@machine_metrics, ", ")} (C159)")]

  defp check(%AST.MetricSource{name: name, devices: [_ | _] = devices}, _ctx) when name in ["mem", "power"],
    do: [error(hd(devices), "#{name} takes no device selector (C159)")]

  defp check(%AST.MetricSource{name: "disk", devices: devices}, _ctx) do
    for %AST.NumberLiteral{} = device <- devices do
      error(device, "disk selects devices by name, e.g. disk[\"nvme0n1\"], not #{device.raw} (C159)")
    end
  end

  defp check(%AST.MetricSource{name: name, devices: devices}, _ctx) do
    for %AST.StringLiteral{value: value} = device <- devices do
      error(device, "#{name} selects devices by number, not #{inspect(value)} (C159)")
    end
  end

  defp check(%AST.MetricsPort{value: value}, _ctx), do: port(value, "metricsPort")

  defp check(%AST.TargetTopics{topics: topics}, _ctx) do
    duplicates(topics, & &1.metric, fn metric, first ->
      "duplicate topic for #{metric} (first at #{position(first)}) (C163)"
    end)
  end

  defp check(%AST.Topic{metric: metric, value: %AST.StringLiteral{value: topic} = value} = node, _ctx) do
    known = known_metric(node, metric)

    if topic == "" or String.contains?(topic, ["+", "#"]),
      do: known ++ [error(value, "topic #{inspect(topic)} must name one topic, without wildcards (C163)")],
      else: known
  end

  @mqtt_settings %{AST.MqttBroker => "broker", AST.MqttQos => "qos", AST.MqttFields => "fields"}

  defp check(%AST.Mqtt{settings: settings} = node, _ctx) do
    dups =
      duplicates(settings, &@mqtt_settings[&1.__struct__], fn name, first ->
        "duplicate #{name} in mqtt (first at #{position(first)}) (C163)"
      end)

    if Enum.any?(settings, &match?(%AST.MqttBroker{}, &1)),
      do: dups,
      else: dups ++ [error(node, "mqtt needs a broker, e.g. broker = \"mqtt://broker.local:1883\"; (C163)")]
  end

  defp check(%AST.MqttBroker{value: %AST.StringLiteral{value: url} = value}, _ctx) do
    case URI.new(url) do
      {:ok, %URI{scheme: "mqtt", host: host}} when host not in [nil, ""] -> []
      _ -> [error(value, "broker #{inspect(url)} must be an mqtt:// URL with a host (C163)")]
    end
  end

  defp check(%AST.MqttQos{value: %AST.NumberLiteral{value: value, raw: raw} = node}, _ctx)
       when value not in [0, 1, 2],
       do: [error(node, "qos #{raw} must be 0, 1 or 2 (C163)")]

  defp check(%AST.MqttFields{fields: fields}, _ctx) do
    duplicates(fields, & &1.metric, fn metric, first ->
      "duplicate field for #{metric} (first at #{position(first)}) (C163)"
    end)
  end

  defp check(%AST.MonitorFields{fields: fields}, _ctx) do
    duplicates(fields, & &1.metric, fn metric, first ->
      "duplicate field for #{metric} (first at #{position(first)}) (C158)"
    end)
  end

  defp check(%AST.MetricField{metric: metric, path: %AST.StringLiteral{value: path} = value} = node, _ctx) do
    known = known_metric(node, metric)

    if path =~ ~r/^[^\s.]+(\.[^\s.]+)*$/,
      do: known,
      else:
        known ++
          [
            error(
              value,
              "field #{inspect(path)} must be a metric name or a dotted JSON path, e.g. \"ENERGY.Power\" (C158, C163)"
            )
          ]
  end

  @monitoring_settings %{
    AST.MonitorInterval => "interval",
    AST.MonitorPort => "port",
    AST.MonitorPath => "path",
    AST.MonitorFormat => "format",
    AST.CarbonIntensity => "carbonIntensity",
    AST.Mqtt => "mqtt",
    AST.MonitorFields => "fields"
  }

  defp check(%AST.Monitoring{settings: settings}, _ctx) do
    duplicates(settings, &@monitoring_settings[&1.__struct__], fn name, first ->
      "duplicate #{name} in monitoring (first at #{position(first)}) (C158)"
    end)
  end

  defp check(%AST.MonitorInterval{value: %AST.TimeLiteral{parts: parts} = value}, _ctx) do
    if Enum.all?(parts, &(&1.value == 0)),
      do: [error(value, "interval #{value.raw} must be greater than 0 (C158)")],
      else: []
  end

  defp check(%AST.MonitorPort{value: value}, _ctx), do: port(value, "port")

  defp check(%AST.MonitorPath{value: %AST.StringLiteral{value: path} = value}, _ctx) do
    if String.starts_with?(path, "/"),
      do: [],
      else: [error(value, "path #{inspect(path)} must start with \"/\" (C158)")]
  end

  defp check(%AST.MonitorFormat{value: format} = node, _ctx) when format not in ["prometheus", "json"],
    do: [error(node, "unknown format #{format}; use prometheus or json (C158)")]

  defp check(%AST.CarbonIntensity{value: %AST.CarbonIntensityLiteral{value: amount, raw: raw} = value}, _ctx)
       when amount == 0,
       do: [error(value, "carbonIntensity #{raw} must be greater than 0 (C161)")]

  defp check(%AST.Host{value: %AST.StringLiteral{value: host} = value}, _ctx) do
    if host =~ ~r{^[^\s/]+$},
      do: [],
      else: [
        error(value, "host #{inspect(host)} must be a host name or address, without scheme or path (C156)")
      ]
  end

  @output_settings %{
    AST.RequestsOutput => "requests",
    AST.SamplesOutput => "samples",
    AST.SummaryOutput => "summary"
  }

  defp check(%AST.Output{settings: settings}, _ctx) do
    duplicates(settings, &@output_settings[&1.__struct__], fn name, first ->
      "duplicate #{name} in output (first at #{position(first)}) (C119)"
    end)
  end

  @requests_settings %{
    AST.OutputFile => "file",
    AST.OutputFields => "fields",
    AST.IncludeWarmup => "includeWarmup"
  }

  defp check(%AST.RequestsOutput{settings: settings} = node, _ctx) do
    dups =
      duplicates(settings, &@requests_settings[&1.__struct__], fn name, first ->
        "duplicate #{name} in requests (first at #{position(first)}) (C122)"
      end)

    file =
      if Enum.any?(settings, &match?(%AST.OutputFile{}, &1)),
        do: [],
        else: [error(node, "requests needs a file, e.g. file = \"results/requests.jsonl\"; (C122)")]

    dups ++ file
  end

  defp check(%AST.SamplesOutput{value: %AST.StringLiteral{value: path} = value}, _ctx) do
    if Path.extname(path) == ".jsonl",
      do: [],
      else: [error(value, "samples file #{inspect(path)} must end in .jsonl (C173)")]
  end

  defp check(%AST.OutputFile{value: %AST.StringLiteral{value: path} = value}, _ctx) do
    if Path.extname(path) == ".jsonl",
      do: [],
      else: [error(value, "requests file #{inspect(path)} must end in .jsonl (C120)")]
  end

  # warmup is not a field: includeWarmup adds it (C122).
  @request_fields ~w(time run test phase virtualUser iteration target method url status latency outcome attempt)

  defp check(%AST.OutputFields{fields: []} = node, _ctx),
    do: [error(node, "fields needs at least one field; leave it out to write all fields (C122)")]

  defp check(%AST.OutputFields{fields: fields}, _ctx) do
    unknown =
      for %AST.FieldName{name: name} = field <- fields, name not in @request_fields do
        if name == "warmup",
          do:
            error(field, "warmup is not a field; includeWarmup = true; writes warmup requests with it (C122)"),
          else: error(field, "unknown field #{name}; use #{Enum.join(@request_fields, ", ")} (C122)")
      end

    dups =
      fields
      |> Enum.filter(&(&1.name in @request_fields))
      |> duplicates(& &1.name, fn name, first ->
        "duplicate field #{name} (first at #{position(first)}) (C122)"
      end)

    unknown ++ dups
  end

  defp check(%AST.SummaryOutput{value: %AST.StringLiteral{value: path} = value}, _ctx) do
    if Path.extname(path) == ".json",
      do: [],
      else: [error(value, "summary file #{inspect(path)} must end in .json (C121)")]
  end

  # ---------- runs (C178) ----------

  @runs_settings %{AST.RunsCount => "count", AST.RunsCooldown => "cooldown", AST.RunsDiscard => "discard"}

  defp check(%AST.Runs{settings: settings}, _ctx) do
    dups =
      duplicates(settings, &@runs_settings[&1.__struct__], fn name, first ->
        "duplicate #{name} in runs (first at #{position(first)}) (C178)"
      end)

    count = Enum.find_value(settings, 1, &(match?(%AST.RunsCount{}, &1) && &1.value.value))
    discard = Enum.find(settings, &match?(%AST.RunsDiscard{}, &1))

    counted =
      if discard && count >= 1 && discard.value.value >= count,
        do: [
          error(
            discard.value,
            "discard #{discard.value.raw} leaves no counted run; it must be below count #{count} (C178)"
          )
        ],
        else: []

    dups ++ counted
  end

  defp check(%AST.RunsCount{value: %AST.NumberLiteral{value: 0} = value}, _ctx),
    do: [error(value, "count 0 runs nothing; it must be at least 1 (C178)")]

  # ---------- retry (C85) ----------

  @retry_entries %{AST.Attempts => "attempts", AST.Delay => "delay", AST.Backoff => "backoff"}

  defp check(%AST.Retry{entries: entries}, _ctx) do
    duplicates(entries, &@retry_entries[&1.__struct__], fn name, first ->
      "duplicate retry entry #{name} (first at #{position(first)}) (C85)"
    end)
  end

  # ---------- requestTimeout (C96) ----------

  defp check(%AST.RequestTimeout{value: %AST.TimeLiteral{parts: parts} = value}, _ctx) do
    if Enum.all?(parts, &(&1.value == 0)),
      do: [error(value, "requestTimeout #{value.raw} must be greater than 0 (C96)")],
      else: []
  end

  # ---------- now stages (C127) ----------

  # The run ends with the last stage, so a now stage there changes nothing.
  defp check(%AST.Stages{stages: stages}, _ctx) do
    case List.last(stages) do
      %AST.NowStage{users: users} = stage ->
        [
          error(
            stage,
            "#{users.raw} now is the last stage; the run ends there, so it never takes effect (C127)"
          )
        ]

      _ ->
        []
    end
  end

  # ---------- Iteration counts (C102) ----------

  defp check(%AST.IterationsLiteral{value: 0} = node, _ctx),
    do: [error(node, "iteration count #{node.raw} must be greater than 0 (C102)")]

  # A ramp changes the user count while it runs, and its curve runs over a
  # total, so a count per user only fits a hold stage (C175).
  defp check(%AST.RampStage{users: users, duration: %AST.IterationsLiteral{per_user: true} = duration}, _ctx) do
    total = String.trim_trailing(duration.raw, "/vu")

    [
      error(
        duration,
        "#{users.raw} in #{duration.raw}: a count per user only works in a for stage; " <>
          "a ramp takes a total such as #{total} (C175)"
      )
    ]
  end

  # ---------- distribution (C36, C87) ----------

  defp check(%AST.Distribution{entries: entries} = node, _ctx) do
    dups =
      duplicates(entries, & &1.target, fn target, first ->
        "duplicate distribution target #{target} (first at #{position(first)}) (C87)"
      end)

    too_big =
      for %AST.DistributionEntry{percentage: %{hundredths: h}} = e <- entries, h > 10_000 do
        error(e.percentage, "distribution value #{e.percentage.raw} for #{e.target} is above 100% (C87)")
      end

    total = entries |> Enum.map(& &1.percentage.hundredths) |> Enum.sum()

    sum =
      if total == 10_000,
        do: [],
        else: [error(node, "distribution adds up to #{percent(total)}, must be exactly 100% (C36)")]

    dups ++ too_big ++ sum
  end

  # ---------- Time literals (C31, C80, C81) ----------

  defp check(%AST.TimeLiteral{parts: [_first | later] = parts} = node, _ctx) do
    capped =
      for %AST.TimePart{unit: unit, value: value} <- later, unit != :h, value >= cap(unit) do
        error(
          node,
          "#{node.raw}: #{unit_name(unit)} must be below #{cap(unit)} after the first part (C31, C80)"
        )
      end

    decimals =
      for %AST.TimePart{raw: raw} = part <- Enum.drop(parts, -1), String.contains?(raw, ".") do
        error(node, "#{node.raw}: only the last part may have decimals, not #{raw}#{part.unit} (C81)")
      end

    capped ++ decimals
  end

  # ---------- http calls (C112-C115, C123) ----------

  defp check(%AST.Call{callee: %AST.Member{object: %AST.Http{}}} = node, _ctx),
    do: http_call(node, :standalone)

  defp check(%AST.Call{callee: %AST.Member{object: %AST.Member{name: "http"}}} = node, _ctx),
    do: http_call(node, :target)

  defp check(%AST.Http{} = node, _ctx),
    do: [
      error(
        node,
        "http can only be called as http.<method>(...), e.g. http.get(\"https://example.com\") (C112)"
      )
    ]

  # ---------- sleep (C133) ----------

  defp check(%AST.Call{callee: %AST.Var{name: "sleep"}} = node, _ctx), do: sleep_call(node, node.args)

  defp check(%AST.FnDeclaration{name: "sleep"} = node, _ctx),
    do: [error(node, "a function cannot be named sleep; it is a built-in (C133)")]

  # ---------- random (C134) ----------

  defp check(%AST.Call{callee: %AST.Member{name: "random"}, args: [_, _ | _] = args} = node, _ctx),
    do: [error(node, "random takes at most one count, got #{length(args)} arguments (C134)")]

  # ---------- Statements (C63, C74) ----------

  defp check(%AST.ExpressionStatement{expression: expr}, _ctx) do
    if call?(expr),
      do: [],
      else: [
        error(start(expr), "a bare expression must be a call; keep its value with let or remove it (C63)")
      ]
  end

  defp check(%AST.Return{} = node, %{in_function: false}),
    do: [error(node, "return is only allowed inside a function (C74)")]

  # ---------- Naming (C46) ----------

  defp check(%AST.Let{name: name} = node, _ctx), do: camel(node, "variable", name)
  defp check(%AST.FnDeclaration{name: name} = node, _ctx), do: camel(node, "function", name)
  defp check(%AST.Param{name: name} = node, _ctx), do: camel(node, "parameter", name)
  defp check(%AST.LambdaParam{name: name} = node, _ctx), do: camel(node, "parameter", name)
  defp check(%AST.For{var: var} = node, _ctx), do: camel(node, "loop variable", var)
  defp check(%AST.BindPattern{name: name} = node, _ctx), do: camel(node, "match binding", name)

  defp check(%AST.CurveDefinition{name: name, params: params} = node, _ctx),
    do: camel(node, "curve", name) ++ Enum.flat_map(params, &camel(node, "curve parameter", &1))

  defp check(%AST.Type{name: name} = node, _ctx) do
    if name =~ ~r/^[A-Z][A-Za-z0-9]*$/,
      do: [],
      else: [error(node, "type name #{name} must be PascalCase (C46)")]
  end

  defp check(_node, _ctx), do: []

  # ---------- Config helpers (C158, C159) ----------

  defp port(%AST.NumberLiteral{value: value}, _name) when value in 1..65535, do: []

  defp port(%AST.NumberLiteral{raw: raw} = node, name),
    do: [error(node, "#{name} #{raw} must be from 1 to 65535 (C158)")]

  defp known_metric(_node, metric) when metric in @machine_metrics, do: []

  defp known_metric(node, metric),
    do: [error(node, "unknown metric #{metric}; use #{Enum.join(@machine_metrics, ", ")} (C159)")]

  defp measured_target(%AST.SutTarget{name: name, settings: settings}) do
    measured = Enum.find(settings, &match?(%AST.TargetMetrics{}, &1))
    port = Enum.find(settings, &match?(%AST.MetricsPort{}, &1))
    machine? = Enum.any?(settings, &(match?(%AST.Host{}, &1) or match?(%AST.BaseUrl{}, &1)))
    listed = for %AST.TargetMetrics{metrics: metrics} <- settings, metric <- metrics, do: metric.name
    topics = for %AST.TargetTopics{topics: topics} <- settings, topic <- topics, do: topic
    from_agent = listed -- Enum.map(topics, & &1.metric)

    unlisted =
      for %AST.Topic{metric: metric} = topic <- topics, metric in @machine_metrics, metric not in listed do
        error(topic, "topic for #{metric} needs #{metric} in the metrics of target #{name} (C163)")
      end

    cond do
      measured && from_agent != [] && not machine? ->
        [
          error(
            measured,
            "target #{name} lists metrics from an agent, so it needs a host or a baseUrl (C159)"
          )
        ] ++ unlisted

      port && !measured ->
        [error(port, "metricsPort needs metrics in target #{name} (C159)")] ++ unlisted

      true ->
        unlisted
    end
  end

  # ---------- Load helpers (C124, C167) ----------

  # Warmup is the first part of the stages, so it must leave some of them. With
  # an iteration count their length is only known at run time.
  defp warmup_length(settings) do
    warmup = Enum.find(settings, &match?(%AST.Warmup{}, &1))
    stages = for %AST.Stages{stages: stages} <- settings, stage <- stages, do: stage
    lengths = Enum.map(stages, &stage_length/1)

    cond do
      warmup == nil or stages == [] or :unknown in lengths -> []
      milliseconds(warmup.value) < Enum.sum(lengths) -> []
      true -> [error(warmup, "warmup #{warmup.value.raw} must be shorter than the stages (C167)")]
    end
  end

  defp stage_length(%AST.NowStage{}), do: 0
  defp stage_length(%{duration: %AST.TimeLiteral{} = duration}), do: milliseconds(duration)
  defp stage_length(_stage), do: :unknown

  defp milliseconds(%AST.TimeLiteral{parts: parts}) do
    Enum.reduce(parts, 0, fn %AST.TimePart{unit: unit, value: value}, total ->
      total + value * @unit_milliseconds[unit]
    end)
  end

  # Without stages, Load runs one iteration with one virtual user (C124).
  # warmup would swallow that iteration, and distribution has nothing to
  # split, so both point to forgotten stages.
  defp without_stages(settings) do
    if Enum.any?(settings, &match?(%AST.Stages{}, &1)) do
      []
    else
      for setting <- settings, reason = without_stages_reason(setting) do
        error(setting, "#{@load_settings[setting.__struct__]} needs stages; #{reason} (C124)")
      end
    end
  end

  defp without_stages_reason(%AST.Warmup{}),
    do: "without stages the single iteration falls inside the warmup and no metric is recorded"

  defp without_stages_reason(%AST.Distribution{}),
    do: "without stages one virtual user runs one iteration, so there is nothing to distribute"

  defp without_stages_reason(_setting), do: nil

  # ---------- http helpers (C112-C115) ----------

  @http_methods ~w(get head delete post put patch)
  @body_methods ~w(post put patch)
  @http_options ~w(headers query)

  defp http_call(%AST.Call{callee: %AST.Member{name: method} = callee, args: args} = node, kind) do
    if method in @http_methods do
      # With the wrong number of arguments the options position is unclear.
      case http_arity(node, method, args) do
        [] -> http_url(args, method, kind) ++ http_body(args, method) ++ http_options(args, method)
        arity -> arity ++ http_url(args, method, kind)
      end
    else
      [error(callee, "unknown http method #{method}; use get, head, delete, post, put or patch (C112)")]
    end
  end

  defp http_arity(_node, method, args) when method in @body_methods and length(args) in 1..3, do: []
  defp http_arity(_node, method, args) when method not in @body_methods and length(args) in 1..2, do: []

  defp http_arity(node, method, args) when method in @body_methods,
    do: [
      error(
        node,
        "http.#{method} takes a URL, an optional body and an optional options object, got #{length(args)} arguments (C113)"
      )
    ]

  defp http_arity(node, method, args),
    do: [
      error(
        node,
        "http.#{method} takes a URL and an optional options object, got #{length(args)} arguments (C113)"
      )
    ]

  defp http_url([%AST.StringLiteral{value: url} = arg | _], method, :standalone) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and host not in [nil, ""] ->
        []

      _ ->
        [
          error(
            arg,
            "http.#{method} without a target needs a full http:// or https:// URL, not #{inspect(url)}; " <>
              "for a path use sut.<target>.http.#{method} (C114)"
          )
        ]
    end
  end

  defp http_url([%AST.StringLiteral{value: url} = arg | _], method, :target) do
    if String.starts_with?(url, "/"),
      do: [],
      else: [
        error(
          arg,
          "path #{inspect(url)} in http.#{method} must start with \"/\"; the target's baseUrl comes before it (C114)"
        )
      ]
  end

  defp http_url(_args, _method, _kind), do: []

  # A body is a JSON value or a string (C123). A unit literal has no JSON
  # form; names and other expressions are left to the Semantic Analyzer.
  @unit_literals [
    AST.TimeLiteral,
    AST.EnergyLiteral,
    AST.PowerLiteral,
    AST.CarbonLiteral,
    AST.UsersLiteral,
    AST.PercentageLiteral
  ]

  defp http_body([_url, %struct{} = body | _], method)
       when method in @body_methods and struct in @unit_literals,
       do: [
         error(body, "the body of http.#{method} must be a JSON value or a string, not #{body.raw} (C123)")
       ]

  defp http_body(_args, _method), do: []

  # The options object is the last argument: the 2nd for get, head and
  # delete, the 3rd for post, put and patch. Only literals are checked.
  defp http_options(args, method) do
    case Enum.at(args, if(method in @body_methods, do: 2, else: 1)) do
      %AST.JsonObject{members: members} ->
        unknown =
          for %AST.JsonMember{key: key} = member <- members, key not in @http_options do
            error(member, "unknown http option #{inspect(key)}; use \"headers\" or \"query\" (C115)")
          end

        dups =
          members
          |> Enum.filter(&(&1.key in @http_options))
          |> duplicates(& &1.key, fn key, first ->
            "duplicate http option #{inspect(key)} (first at #{position(first)}) (C115)"
          end)

        not_objects =
          for %AST.JsonMember{key: key, value: value} <- members, key in @http_options, literal?(value) do
            error(value, "http option #{inspect(key)} must be a JSON object (C115)")
          end

        unknown ++ dups ++ not_objects

      nil ->
        []

      options ->
        if literal?(options),
          do: [error(options, "the options of http.#{method} must be a JSON object (C115)")],
          else: []
    end
  end

  # A literal value that is not a JSON object. Names, calls and other
  # expressions are left to the Semantic Analyzer.
  defp literal?(%AST.JsonArray{}), do: true
  defp literal?(%AST.Null{}), do: true
  defp literal?(%AST.BoolLiteral{}), do: true

  defp literal?(%struct{}),
    do: struct |> Module.split() |> List.last() |> String.ends_with?("Literal")

  defp literal?(_), do: false

  # ---------- sleep helpers (C133) ----------

  defp sleep_call(_node, [%AST.TimeLiteral{}]), do: []

  defp sleep_call(_node, [%AST.Unary{op: :-, operand: %AST.TimeLiteral{raw: raw}} = arg]),
    do: [error(arg, "sleep(-#{raw}) must not be negative (C133)")]

  # Names and other expressions are left to the Semantic Analyzer.
  defp sleep_call(_node, [arg]) do
    if literal?(arg),
      do: [error(arg, "sleep takes a Time such as 2s (C133)")],
      else: []
  end

  defp sleep_call(node, args),
    do: [error(node, "sleep takes one Time, got #{length(args)} arguments (C133)")]

  # ---------- Helpers ----------

  # A bare call: f(x), a.b(x), list operations and metrics are all written as calls.
  defp call?(%AST.Call{}), do: true
  defp call?(%AST.ListOperation{}), do: true
  defp call?(%AST.Metric{}), do: true
  defp call?(_), do: false

  # The leftmost node of an expression, so errors point at where it starts
  # rather than at its operator (x + 1 is reported at x, not at +).
  defp start(%AST.Binary{left: left}), do: start(left)
  defp start(%AST.Member{object: object}), do: start(object)
  defp start(%AST.Index{object: object}), do: start(object)
  defp start(%AST.Call{callee: callee}), do: start(callee)
  defp start(%AST.ListOperation{receiver: receiver}), do: start(receiver)
  defp start(node), do: node

  defp camel(node, what, name) do
    if name =~ ~r/^[a-z][A-Za-z0-9]*$/,
      do: [],
      else: [error(node, "#{what} name #{name} must be camelCase (C46)")]
  end

  # One error per repeat, at the repeat, pointing back at the first occurrence.
  defp duplicates(items, key_fun, message_fun) do
    {errors, _seen} =
      Enum.reduce(items, {[], %{}}, fn item, {errors, seen} ->
        key = key_fun.(item)

        case seen do
          %{^key => first} -> {[error(item, message_fun.(key, first)) | errors], seen}
          _ -> {errors, Map.put(seen, key, item)}
        end
      end)

    Enum.reverse(errors)
  end

  # Hours can only be the first part, which is never capped (C80).
  defp cap(:ms), do: 1000
  defp cap(unit) when unit in [:m, :s], do: 60

  defp unit_name(:m), do: "minutes"
  defp unit_name(:s), do: "seconds"
  defp unit_name(:ms), do: "milliseconds"

  # 9999 -> "99.99%", 10010 -> "100.1%", 10000 -> "100%"
  defp percent(hundredths) do
    whole = div(hundredths, 100)

    case rem(hundredths, 100) do
      0 ->
        "#{whole}%"

      frac ->
        "#{whole}.#{frac |> Integer.to_string() |> String.pad_leading(2, "0") |> String.trim_trailing("0")}%"
    end
  end

  defp position(%{loc: {line, column}}), do: "#{line}:#{column}"

  defp error(%{loc: {line, column}}, message),
    do: %Error{stage: :validator, message: message, line: line, column: column}
end
