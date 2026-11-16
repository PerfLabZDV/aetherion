defmodule PerfLang.AST do
  @moduledoc """
  The PerfLang abstract syntax tree.

  Every node is a struct with a `loc` field holding `{line, column}` of
  its defining token: the keyword for statements, blocks and settings,
  the operator for binary, unary, member, call, index and list-operation
  expressions, and the first token otherwise. Columns count characters
  and start at 1.

  The tree keeps everything the later passes need and does not resolve
  or check anything the grammar defers ("checked after parsing"):

    * The Validator works on structure: duplicate Load settings (C78)
      and retry entries (C85), distribution totals (C36, C87), Time part
      ranges and decimals (C31, C80, C81), bare expression statements
      (C63). Settings and entries are kept in source order, percentages
      carry exact `hundredths`, and Time literals keep every part with
      its raw text.
    * The Semantic Analyzer works on names, types and units: `Var`,
      `Type`, `Lambda`, `ListOperation`, `Metric` and the unit literals.
      It fills the `type` field of every expression; the parser and the
      Validator leave it nil. `PerfLang.Analyzer` lists the type values.

  Names are strings. Operators, units, metric groups and measurements
  are atoms from a fixed set.
  """

  # ---------- Structure ----------

  defmodule TestSuite do
    @moduledoc "TestSuite name { [Config] [Functions] [Load] Test+ }. `config` and `functions` are nil when not written."
    defstruct [:loc, :name, :config, :functions, :load, :tests]
  end

  defmodule Test do
    @moduledoc "Test name { [Load] [Setup] Actions [Verify] [Cleanup] }. Missing optional parts are nil."
    defstruct [:loc, :name, :load, :setup, :actions, :verify, :cleanup]
  end

  defmodule Phase do
    @moduledoc "A test phase. `kind` is :setup, :actions, :verify or :cleanup."
    defstruct [:loc, :kind, statements: []]
  end

  defmodule Load do
    @moduledoc "Load { ... }. `settings` keeps source order; duplicates are left for the Validator."
    defstruct [:loc, settings: []]
  end

  # ---------- Config ----------

  defmodule Config do
    @moduledoc "Config { ... }. `sections` keeps source order; duplicates are left for the Validator."
    defstruct [:loc, sections: []]
  end

  defmodule Sut, do: defstruct([:loc, targets: []])

  defmodule Workers do
    @moduledoc "workers { ... }: the machines that run the virtual users (C181)."
    defstruct [:loc, workers: []]
  end

  defmodule Worker do
    @moduledoc "name { host = \"...\"; } inside workers. `settings` keeps source order; duplicates are left for the Validator."
    defstruct [:loc, :name, settings: []]
  end

  defmodule SutTarget do
    @moduledoc "name { ... } inside sut. `settings` keeps source order; duplicates are left for the Validator."
    defstruct [:loc, :name, settings: []]
  end

  defmodule BaseUrl do
    @moduledoc "baseUrl = \"...\"; `value` is a StringLiteral."
    defstruct [:loc, :value]
  end

  defmodule Host do
    @moduledoc "host = \"...\"; the machine of a target (C156). `value` is a StringLiteral."
    defstruct [:loc, :value]
  end

  defmodule TargetMetrics do
    @moduledoc "metrics = [cpu, mem]; what is measured on a target's machine (C159). `metrics` is a list of MetricSource."
    defstruct [:loc, metrics: []]
  end

  defmodule MetricSource do
    @moduledoc "cpu[0, 1] in metrics. `devices` holds NumberLiteral and StringLiteral nodes, empty for all devices."
    defstruct [:loc, :name, devices: []]
  end

  defmodule MetricsPort do
    @moduledoc "metricsPort = 9400; replaces the monitoring port for one target (C159). `value` is a NumberLiteral."
    defstruct [:loc, :value]
  end

  defmodule TargetTopics do
    @moduledoc "topics { power = \"...\"; }: the metrics of a target that come over MQTT (C163). `topics` is a list of Topic."
    defstruct [:loc, topics: []]
  end

  defmodule Topic do
    @moduledoc "power = \"tele/app/SENSOR\"; `metric` is a name, `value` a StringLiteral."
    defstruct [:loc, :metric, :value]
  end

  defmodule Monitoring do
    @moduledoc "monitoring { ... } (C158). `settings` keeps source order; duplicates are left for the Validator."
    defstruct [:loc, settings: []]
  end

  defmodule MonitorInterval, do: defstruct([:loc, :value])
  defmodule MonitorPort, do: defstruct([:loc, :value])
  defmodule MonitorPath, do: defstruct([:loc, :value])

  defmodule MonitorFormat do
    @moduledoc "format = prometheus; `value` is a name, checked by the Validator."
    defstruct [:loc, :value]
  end

  defmodule Mqtt do
    @moduledoc "mqtt { ... } in monitoring (C163). `settings` keeps source order; duplicates are left for the Validator."
    defstruct [:loc, settings: []]
  end

  defmodule MqttBroker, do: defstruct([:loc, :value])
  defmodule MqttQos, do: defstruct([:loc, :value])

  defmodule MqttFields do
    @moduledoc "fields { power = \"ENERGY.Power\"; } in mqtt. `fields` is a list of MetricField."
    defstruct [:loc, fields: []]
  end

  defmodule MonitorFields do
    @moduledoc "fields { gpu = \"DCGM_FI_DEV_GPU_UTIL\"; } in monitoring (C158). `fields` is a list of MetricField."
    defstruct [:loc, fields: []]
  end

  defmodule MetricField do
    @moduledoc "`metric` is a name, `path` a StringLiteral: a dotted JSON path, or a Prometheus metric name."
    defstruct [:loc, :metric, :path]
  end

  defmodule CarbonIntensity do
    @moduledoc "carbonIntensity = 380gCO2e/kWh; (C161). `value` is a CarbonIntensityLiteral."
    defstruct [:loc, :value]
  end

  defmodule CarbonIntensityLiteral do
    @moduledoc "A value in gCO2e/kWh, only used in the carbonIntensity setting (C161)."
    defstruct [:loc, :value, :raw]
  end

  defmodule Output do
    @moduledoc "output { ... } (C119). `settings` keeps source order; duplicates are left for the Validator."
    defstruct [:loc, settings: []]
  end

  defmodule RequestsOutput do
    @moduledoc "requests { ... } (C120, C122). `settings` keeps source order; duplicates are left for the Validator."
    defstruct [:loc, settings: []]
  end

  defmodule OutputFile do
    @moduledoc "file = \"...\"; inside requests. `value` is a StringLiteral."
    defstruct [:loc, :value]
  end

  defmodule OutputFields do
    @moduledoc "fields = [status, latency]; inside requests. `fields` is a list of FieldName, in source order."
    defstruct [:loc, fields: []]
  end

  defmodule FieldName, do: defstruct([:loc, :name])

  defmodule IncludeWarmup do
    @moduledoc "includeWarmup = true; inside requests. `value` is a BoolLiteral."
    defstruct [:loc, :value]
  end

  defmodule SamplesOutput do
    @moduledoc "samples { file = \"...\"; } (C173). `value` is a StringLiteral."
    defstruct [:loc, :value]
  end

  defmodule SummaryOutput do
    @moduledoc "summary = \"...\"; the file for the metrics at the end of the run (C121). `value` is a StringLiteral."
    defstruct [:loc, :value]
  end

  defmodule Runs do
    @moduledoc "runs { ... } (C178). `settings` keeps source order; duplicates are left for the Validator."
    defstruct [:loc, settings: []]
  end

  defmodule RunsCount do
    @moduledoc "count = 10; inside runs: how many times the suite runs (C178). `value` is a NumberLiteral."
    defstruct [:loc, :value]
  end

  defmodule RunsCooldown do
    @moduledoc "cooldown = 30s; inside runs: the pause between runs (C178). `value` is a TimeLiteral."
    defstruct [:loc, :value]
  end

  defmodule RunsDiscard do
    @moduledoc "discard = 1; inside runs: the first runs, left out of statistics and result (C178). `value` is a NumberLiteral."
    defstruct [:loc, :value]
  end

  # ---------- Load settings ----------

  defmodule Warmup, do: defstruct([:loc, :value])
  defmodule ThinkTime, do: defstruct([:loc, :value])
  defmodule RequestTimeout, do: defstruct([:loc, :value])

  defmodule Curves, do: defstruct([:loc, definitions: []])
  defmodule Stages, do: defstruct([:loc, stages: []])
  defmodule Distribution, do: defstruct([:loc, entries: []])
  defmodule StopIf, do: defstruct([:loc, :condition])
  defmodule Retry, do: defstruct([:loc, entries: []])

  defmodule CurveDefinition do
    @moduledoc "name(params) = body; `params` is a list of names."
    defstruct [:loc, :name, :body, params: []]
  end

  defmodule RampStage do
    @moduledoc """
    users in duration [curve]. `duration` is a TimeLiteral or an IterationsLiteral (C101).
    `curve` is nil when omitted (linear by default, C24).
    """
    defstruct [:loc, :users, :duration, :curve]
  end

  defmodule HoldStage do
    @moduledoc "users for duration. `duration` is a TimeLiteral or an IterationsLiteral (C101)."
    defstruct [:loc, :users, :duration]
  end

  defmodule NowStage do
    @moduledoc "users now: the user count changes at once, with no length (C127)."
    defstruct [:loc, :users]
  end

  defmodule CurveRef do
    @moduledoc "A curve used in a stage. `args` is nil without parentheses (exp), a list with them (wave(3))."
    defstruct [:loc, :name, :args]
  end

  defmodule DistributionEntry, do: defstruct([:loc, :target, :percentage])
  defmodule Attempts, do: defstruct([:loc, :value])
  defmodule Delay, do: defstruct([:loc, :value])

  defmodule Backoff do
    @moduledoc "`strategy` is :fixed, :linear or :exponential."
    defstruct [:loc, :strategy]
  end

  # ---------- Functions and types ----------

  defmodule FnDeclaration, do: defstruct([:loc, :name, :return_type, :body, params: []])
  defmodule Param, do: defstruct([:loc, :name, :type])

  defmodule Type do
    @moduledoc "A type name with optional type arguments: List<Response> has args [Response]."
    defstruct [:loc, :name, args: []]
  end

  # ---------- Statements ----------

  defmodule Block, do: defstruct([:loc, statements: []])
  defmodule Let, do: defstruct([:loc, :name, :type, :value, mutable: false])
  defmodule Assign, do: defstruct([:loc, :name, :value])
  defmodule Assert, do: defstruct([:loc, :condition])
  defmodule Check, do: defstruct([:loc, :condition])

  defmodule If do
    @moduledoc "`else` is nil, a Block, or another If (else if)."
    defstruct [:loc, :condition, :then, :else]
  end

  defmodule While, do: defstruct([:loc, :condition, :body])
  defmodule For, do: defstruct([:loc, :var, :iterable, :body])
  defmodule Return, do: defstruct([:loc, :value])

  defmodule ExpressionStatement do
    @moduledoc "A bare expression followed by ';'. Must be a call (C63), checked by the Validator."
    defstruct [:loc, :expression]
  end

  defmodule MatchStatement do
    @moduledoc "A match used on its own as a statement."
    defstruct [:loc, :match]
  end

  # ---------- Expressions ----------

  defmodule Var, do: defstruct([:loc, :type, :name])

  defmodule Binary do
    @moduledoc "`op` is one of :||, :&&, :==, :!=, :<, :<=, :>, :>=, :+, :-, :*, :/, :^."
    defstruct [:loc, :type, :op, :left, :right]
  end

  defmodule Unary do
    @moduledoc "`op` is :- or :! (C147)."
    defstruct [:loc, :type, :op, :operand]
  end

  defmodule Http do
    @moduledoc "The standalone http client in http.get(...) (C112). A target's client is a Member named \"http\"."
    defstruct [:loc, :type]
  end

  defmodule Member, do: defstruct([:loc, :type, :object, :name])
  defmodule Call, do: defstruct([:loc, :type, :callee, args: []])
  defmodule Index, do: defstruct([:loc, :type, :object, :index])

  defmodule Lambda, do: defstruct([:loc, :type, :body, params: []])
  defmodule LambdaParam, do: defstruct([:loc, :name, :type])

  defmodule ListOperation do
    @moduledoc """
    receiver.map(f), .filter(f), .fold(init, f), .foldl(init, f), .foldr(init, f).
    `op` is :map, :filter, :fold, :foldl or :foldr; `init` is nil for map and filter.
    `function` is a Lambda or a Var.
    """
    defstruct [:loc, :type, :op, :receiver, :init, :function]
  end

  defmodule Metric do
    @moduledoc """
    group.measurement(), e.g. latency.p95(). `group` and `measurement` are atoms;
    `argument` is the NumberLiteral of latency.percentile(n), otherwise nil.
    `target` is nil for the totals, or the Target expression of a request
    metric per target, e.g. sut.europe in sut.europe.latency.p95() (C176). The
    parser reads that form as a call; the Semantic Analyzer makes it a Metric.
    """
    defstruct [:loc, :type, :group, :measurement, :argument, :target]
  end

  defmodule Match, do: defstruct([:loc, :type, :subject, arms: []])

  defmodule MatchArm do
    @moduledoc "`guard` is nil without `if`. `body` is a Block or an expression."
    defstruct [:loc, :pattern, :guard, :body]
  end

  defmodule LiteralPattern do
    @moduledoc "A literal pattern; `negative` is true for -literal."
    defstruct [:loc, :literal, negative: false]
  end

  defmodule BindPattern, do: defstruct([:loc, :name])
  defmodule WildcardPattern, do: defstruct([:loc])

  defmodule JsonObject do
    @moduledoc "{ \"key\": value, ... }. `members` keeps source order; duplicate keys are not checked."
    defstruct [:loc, :type, members: []]
  end

  defmodule JsonMember, do: defstruct([:loc, :key, :value])
  defmodule JsonArray, do: defstruct([:loc, :type, items: []])

  defmodule Null do
    @moduledoc "null, only allowed as a JSON value (C69)."
    defstruct [:loc, :type]
  end

  # ---------- Literals ----------

  defmodule NumberLiteral do
    @moduledoc "`value` is an integer, or a float when written with decimals. `raw` is the source text."
    defstruct [:loc, :type, :value, :raw]
  end

  defmodule TimePart do
    @moduledoc "One part of a Time literal. `unit` is :h, :m, :s or :ms."
    defstruct [:unit, :value, :raw]
  end

  defmodule TimeLiteral do
    @moduledoc "A Time literal, parts largest first: 7m30s has two parts. `raw` is the source text."
    defstruct [:loc, :type, :raw, parts: []]
  end

  defmodule EnergyLiteral do
    @moduledoc "`unit` is :mJ, :J, :kJ, :MJ, :Wh, :kWh or :MWh."
    defstruct [:loc, :type, :value, :unit, :raw]
  end

  defmodule PowerLiteral do
    @moduledoc "`unit` is :mW, :W or :kW."
    defstruct [:loc, :type, :value, :unit, :raw]
  end

  defmodule CarbonLiteral do
    @moduledoc "`unit` is :mgCO2e, :gCO2e or :kgCO2e."
    defstruct [:loc, :type, :value, :unit, :raw]
  end

  defmodule DataRateLiteral do
    @moduledoc "A DataRate in bytes per second (C186). `unit` is :\"B/s\", :\"kB/s\", :\"MB/s\" or :\"GB/s\"."
    defstruct [:loc, :type, :value, :unit, :raw]
  end

  defmodule UsersLiteral do
    @moduledoc "A VirtualUsers literal (C94, C95). `value` is a whole number."
    defstruct [:loc, :type, :value, :raw]
  end

  defmodule IterationsLiteral do
    @moduledoc """
    An iteration count, only used as a stage length (C101-C103). `value` is a whole number.
    `per_user` is true for iter/vu: `value` iterations for each virtual user (C175).
    """
    defstruct [:loc, :value, :raw, per_user: false]
  end

  defmodule PercentageLiteral do
    @moduledoc """
    A Percentage. `hundredths` is the exact value in hundredths of a percent
    (33.33% is 3333), so totals can be compared exactly (C36).
    """
    defstruct [:loc, :type, :value, :hundredths, :raw]
  end

  defmodule StringLiteral do
    @moduledoc "`value` is the string with escapes resolved. `raw` is true for \"\"\"raw\"\"\" strings."
    defstruct [:loc, :type, :value, raw: false]
  end

  defmodule BoolLiteral, do: defstruct([:loc, :type, :value])

  # ---------- Construction (called from the yecc parser) ----------

  @kinds %{
    test_suite: TestSuite,
    test: Test,
    phase: Phase,
    config: Config,
    sut: Sut,
    sut_target: SutTarget,
    workers: Workers,
    worker: Worker,
    base_url: BaseUrl,
    host: Host,
    target_metrics: TargetMetrics,
    metric_source: MetricSource,
    metrics_port: MetricsPort,
    target_topics: TargetTopics,
    topic: Topic,
    monitoring: Monitoring,
    mqtt: Mqtt,
    mqtt_broker: MqttBroker,
    mqtt_qos: MqttQos,
    mqtt_fields: MqttFields,
    monitor_fields: MonitorFields,
    metric_field: MetricField,
    samples_output: SamplesOutput,
    monitor_interval: MonitorInterval,
    monitor_port: MonitorPort,
    monitor_path: MonitorPath,
    monitor_format: MonitorFormat,
    carbon_intensity: CarbonIntensity,
    output: Output,
    requests_output: RequestsOutput,
    output_file: OutputFile,
    output_fields: OutputFields,
    field_name: FieldName,
    include_warmup: IncludeWarmup,
    summary_output: SummaryOutput,
    runs: Runs,
    runs_count: RunsCount,
    runs_cooldown: RunsCooldown,
    runs_discard: RunsDiscard,
    load: Load,
    warmup: Warmup,
    think_time: ThinkTime,
    request_timeout: RequestTimeout,
    curves: Curves,
    stages: Stages,
    distribution: Distribution,
    stop_if: StopIf,
    retry: Retry,
    curve_definition: CurveDefinition,
    ramp_stage: RampStage,
    hold_stage: HoldStage,
    now_stage: NowStage,
    curve_ref: CurveRef,
    distribution_entry: DistributionEntry,
    attempts: Attempts,
    delay: Delay,
    backoff: Backoff,
    fn_declaration: FnDeclaration,
    param: Param,
    type: Type,
    block: Block,
    let: Let,
    assign: Assign,
    assert: Assert,
    check: Check,
    if: If,
    while: While,
    for: For,
    return: Return,
    expression_statement: ExpressionStatement,
    match_statement: MatchStatement,
    var: Var,
    binary: Binary,
    unary: Unary,
    http: Http,
    member: Member,
    call: Call,
    index: Index,
    lambda: Lambda,
    lambda_param: LambdaParam,
    list_operation: ListOperation,
    metric: Metric,
    match: Match,
    match_arm: MatchArm,
    literal_pattern: LiteralPattern,
    bind_pattern: BindPattern,
    wildcard_pattern: WildcardPattern,
    json_object: JsonObject,
    json_member: JsonMember,
    json_array: JsonArray,
    null: Null,
    bool_literal: BoolLiteral
  }

  @doc false
  def new(kind, loc, fields) do
    struct!(Map.fetch!(@kinds, kind), [{:loc, loc} | fields])
  end

  @doc false
  def literal(:number, loc, raw), do: %NumberLiteral{loc: loc, value: number(raw), raw: raw}

  def literal(:time, loc, {raw, parts}) do
    parts = for {num, unit} <- parts, do: %TimePart{unit: unit, value: number(num), raw: num}
    %TimeLiteral{loc: loc, raw: raw, parts: parts}
  end

  def literal(:energy, loc, {raw, num, unit}),
    do: %EnergyLiteral{loc: loc, value: number(num), unit: unit, raw: raw}

  def literal(:power, loc, {raw, num, unit}),
    do: %PowerLiteral{loc: loc, value: number(num), unit: unit, raw: raw}

  def literal(:carbon, loc, {raw, num, unit}),
    do: %CarbonLiteral{loc: loc, value: number(num), unit: unit, raw: raw}

  def literal(:data_rate, loc, {raw, num, unit}),
    do: %DataRateLiteral{loc: loc, value: number(num), unit: unit, raw: raw}

  def literal(:carbon_intensity, loc, {raw, num}),
    do: %CarbonIntensityLiteral{loc: loc, value: number(num), raw: raw}

  def literal(:users, loc, {raw, num}),
    do: %UsersLiteral{loc: loc, value: String.to_integer(num), raw: raw}

  def literal(:iterations, loc, {raw, num}),
    do: %IterationsLiteral{
      loc: loc,
      value: String.to_integer(num),
      raw: raw,
      per_user: String.ends_with?(raw, "/vu")
    }

  def literal(:percentage, loc, {raw, num}) do
    %PercentageLiteral{loc: loc, value: number(num), hundredths: hundredths(num), raw: raw}
  end

  def literal(:string, loc, value), do: %StringLiteral{loc: loc, value: value, raw: false}
  def literal(:raw_string, loc, value), do: %StringLiteral{loc: loc, value: value, raw: true}

  defp number(raw) do
    if String.contains?(raw, "."), do: String.to_float(raw), else: String.to_integer(raw)
  end

  defp hundredths(raw) do
    case String.split(raw, ".") do
      [int] -> String.to_integer(int) * 100
      [int, frac] -> String.to_integer(int) * 100 + String.to_integer(String.pad_trailing(frac, 2, "0"))
    end
  end

  @doc "The `{line, column}` of a node."
  def loc(%{loc: loc}), do: loc
end
