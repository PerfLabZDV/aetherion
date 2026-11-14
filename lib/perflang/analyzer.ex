defmodule PerfLang.Analyzer do
  @moduledoc """
  The Semantic Analyzer: names, types and units (C136-C168).

      {:ok, ast} = PerfLang.Analyzer.analyze(ast, config: config)
      {:error, [%PerfLang.Error{stage: :semantic}, ...]} = PerfLang.Analyzer.analyze(bad_ast)

  Runs after the Validator. `config` is the validated external configuration
  file (C157); its targets replace the ones of the same name in the suite's
  Config, its monitoring replaces the suite's, and the returned AST holds the
  merged Config. It collects every
  error instead of stopping at the first, and returns them sorted by
  position. There are no warnings. The checks:

    * Scope (C136, C149, C150): every name is declared before it is read, in
      a scope that reaches it, and only once per scope. Test, fn and curve
      names are unique in the suite.
    * Shared state (C76, C137): assignments need let mut, Actions does not
      assign to Setup variables, and add needs a let mut list.
    * Types (C59, C123, C138-C142, C153): type names, assignments, arguments,
      return values, conditions, operators and JSON values.
    * Members (C68, C109, C110, C112, C143, C145): Response members, targets,
      list methods and indexing.
    * Target settings (C156, C158-C161): http calls and distribution need a
      baseUrl, machine readings a target that lists the metric, metrics from
      an agent a format, a port and any field they need, topics need mqtt,
      energy, power and carbon metrics a target that lists power, and sut.any
      Actions and a distribution.
    * Built-ins and curves (C28, C56, C144, C152): arguments, curve use in
      stages, curve recursion, and what curves and stopIf may read.
    * Metrics (C146, C154, C176): read in Verify, stopIf and Cleanup only,
      directly or through a fn, and percentile(n) from 0 to 100. Request
      metrics per target, sut.europe.latency.p95(), become a Metric with a
      target; they need a target with a baseUrl and do not work in stopIf.
    * Match (C148), fn returns (C150) and lambda parameters (C151).

  Every expression in the returned AST has its `type` set to one of these:
  `:bool`, `:string`, `:json`, `:unit`, `:int`, `:float`, `:time`, `:energy`,
  `:power`, `:carbon`, `:percentage`, `:users`, `:response`, `:target`,
  `{:list, type}` or `{:fn, params, return}`. `:unknown` is an empty list
  that no use gave a type (C140). A `sut` or `http` namespace has none.
  """

  alias PerfLang.{AST, Error}

  @numbers [:int, :float]
  @units [:time, :energy, :power, :carbon]
  @ordered @units ++ [:percentage, :users]
  @conversions [:int, :float, :bool, :string]
  @text_types [:int, :float, :bool, :string, :json, :unknown] ++ @ordered

  @types %{
    "Bool" => :bool,
    "String" => :string,
    "Json" => :json,
    "Unit" => :unit,
    "Int" => :int,
    "Float" => :float,
    "Time" => :time,
    "Energy" => :energy,
    "Power" => :power,
    "Carbon" => :carbon,
    "Percentage" => :percentage,
    "VirtualUsers" => :users,
    "Response" => :response,
    "Target" => :target
  }

  @type_names Map.new(@types, fn {name, type} -> {type, name} end)

  @response_members %{
    "status" => :int,
    "outcome" => :string,
    "latency" => :time,
    "body" => :json,
    "headers" => :json
  }

  @machine_metrics %{
    "cpu" => :percentage,
    "mem" => :percentage,
    "disk" => :percentage,
    "gpu" => :percentage,
    "power" => :power
  }

  @load_generator_metrics ["cpu", "mem"]

  # The request metrics that work per target, with their measurements (C60, C176).
  @request_metrics %{
    "latency" => {:latency, ~w(p50 p90 p95 p99 mean min max percentile)},
    "throughput" => {:throughput, ~w(perSecond)},
    "errors" => {:errors, ~w(rate count timeouts connectionErrors assertFailures checkFailures)}
  }

  @math ~w(sin cos exp log sqrt abs linear)
  @constants ~w(pi e)
  @curve_arity Map.merge(Map.new(@math, &{&1, 1}), %{"min" => 2, "max" => 2})
  @http_bodies ~w(post put patch)
  @no_context %{phase: nil, fn: nil, curve: nil, return: nil}

  @doc "Analyzes a validated suite. Returns `{:ok, ast}` with typed expressions, or `{:error, errors}` sorted by position."
  @spec analyze(%AST.TestSuite{}, keyword()) :: {:ok, %AST.TestSuite{}} | {:error, [Error.t()]}
  def analyze(%AST.TestSuite{} = ast, opts \\ []) do
    ast = %{ast | config: merge(ast.config, opts[:config])}

    st = %{
      errors: [],
      subst: %{},
      next: 0,
      scopes: [],
      targets: targets(ast.config),
      monitoring: monitoring(ast.config),
      agent_format: agent_format(ast.config),
      agent_fields: agent_fields(ast.config),
      distribution: false,
      fns: %{},
      fn_calls: %{},
      fn_metrics: MapSet.new(),
      metric_fns: MapSet.new(),
      curves: %{},
      curve_calls: %{}
    }

    {ast, st} = suite(ast, ast.config |> measured_targets(st) |> then(&duplicates(ast, &1)))

    case st.errors do
      [] -> {:ok, finish(ast, st)}
      errors -> {:error, errors |> Enum.reverse() |> Enum.sort_by(&{&1.line, &1.column})}
    end
  end

  # A target in the external file replaces the one in the suite as a whole (C157).
  defp merge(config, nil), do: config
  defp merge(nil, %AST.Config{} = external), do: external

  # Its monitoring replaces the one in the suite as a whole too.
  defp merge(%AST.Config{sections: sections} = config, %AST.Config{} = external) do
    added = sut_targets(external)
    names = MapSet.new(added, & &1.name)
    kept = config |> sut_targets() |> Enum.reject(&MapSet.member?(names, &1.name))
    replaced = for section <- external.sections, not match?(%AST.Sut{}, section), do: section.__struct__
    others = Enum.reject(sections, &(match?(%AST.Sut{}, &1) or &1.__struct__ in replaced))
    from_file = Enum.reject(external.sections, &match?(%AST.Sut{}, &1))

    sut =
      if Enum.any?(sections ++ external.sections, &match?(%AST.Sut{}, &1)),
        do: [%AST.Sut{loc: config.loc, targets: kept ++ added}],
        else: []

    %{config | sections: sut ++ others ++ from_file}
  end

  defp sut_targets(%AST.Config{sections: sections}) do
    for %AST.Sut{targets: targets} <- sections, target <- targets, do: target
  end

  defp targets(nil), do: %{}

  defp targets(%AST.Config{} = config) do
    Map.new(sut_targets(config), fn %AST.SutTarget{name: name, settings: settings} ->
      {name,
       %{
         base_url: Enum.any?(settings, &match?(%AST.BaseUrl{}, &1)),
         metrics: for(%AST.TargetMetrics{metrics: metrics} <- settings, m <- metrics, do: m.name)
       }}
    end)
  end

  defp monitoring(nil), do: []

  defp monitoring(%AST.Config{sections: sections}) do
    for %AST.Monitoring{settings: settings} <- sections, setting <- settings, do: setting.__struct__
  end

  defp agent_format(nil), do: nil

  defp agent_format(%AST.Config{sections: sections}) do
    List.first(
      for %AST.Monitoring{settings: settings} <- sections,
          %AST.MonitorFormat{value: format} <- settings,
          do: format
    )
  end

  defp agent_fields(nil), do: []

  defp agent_fields(%AST.Config{sections: sections}) do
    for %AST.Monitoring{settings: settings} <- sections,
        %AST.MonitorFields{fields: fields} <- settings,
        field <- fields,
        do: field.metric
  end

  # With prometheus the engine computes cpu, mem and disk from node_exporter;
  # everything else names where the value is (C158).
  defp needs_field?("prometheus", metric), do: metric in ["gpu", "power"]
  defp needs_field?(_format, _metric), do: true

  # Metrics from an agent need a format and a port, which metricsPort may give
  # (C158). Metrics with a topic come over MQTT instead (C163).
  defp measured_targets(nil, st), do: st

  defp measured_targets(%AST.Config{} = config, st) do
    Enum.reduce(sut_targets(config), st, fn %AST.SutTarget{name: name, settings: settings} = target, st ->
      listed = for %AST.TargetMetrics{metrics: metrics} <- settings, metric <- metrics, do: metric.name
      topics = for %AST.TargetTopics{topics: topics} <- settings, topic <- topics, do: topic.metric
      own_port? = Enum.any?(settings, &match?(%AST.MetricsPort{}, &1))

      cond do
        topics != [] and AST.Mqtt not in st.monitoring ->
          error(st, target, "target #{name} has topics, so monitoring needs mqtt (C163)")

        listed -- topics == [] ->
          st

        AST.MonitorFormat not in st.monitoring ->
          error(st, target, "target #{name} lists metrics from an agent, so monitoring needs a format (C158)")

        AST.MonitorPort not in st.monitoring and not own_port? ->
          error(
            st,
            target,
            "target #{name} lists metrics from an agent, so monitoring needs a port, or the target a metricsPort (C158)"
          )

        true ->
          missing =
            (listed -- topics)
            |> Enum.filter(&needs_field?(st.agent_format, &1))
            |> Enum.reject(&(&1 in st.agent_fields))

          Enum.reduce(missing, st, fn metric, st ->
            error(
              st,
              target,
              "target #{name} reads #{metric} from an agent, so monitoring needs a field for it (C158)"
            )
          end)
      end
    end)
  end

  # ---------- Suite ----------

  defp suite(ast, st) do
    declarations = ast.functions || []
    {signatures, st} = Enum.map_reduce(declarations, st, &signature/2)

    st = %{
      st
      | fns: declarations |> Enum.zip(signatures) |> Enum.reverse() |> Map.new(fn {d, s} -> {d.name, s} end)
    }

    {functions, st} =
      declarations |> Enum.zip(signatures) |> Enum.map_reduce(st, &function/2)

    st = %{st | metric_fns: metric_fns(st)}
    {load, st} = load(ast.load, st)
    {tests, st} = Enum.map_reduce(ast.tests, %{st | distribution: distribution?(ast.load)}, &test/2)
    functions = if ast.functions, do: functions

    {%{ast | functions: functions, load: load, tests: tests}, st}
  end

  defp distribution?(nil), do: false
  defp distribution?(%AST.Load{settings: settings}), do: Enum.any?(settings, &match?(%AST.Distribution{}, &1))

  defp test(%AST.Test{} = test, st) do
    {load, st} = load(test.load, st)
    st = if test.load, do: %{st | distribution: distribution?(test.load)}, else: st
    {setup, setup_scope, st} = phase(test.setup, [], st)
    {actions, actions_scope, st} = phase(test.actions, [setup_scope], st)
    {verify, _, st} = phase(test.verify, [actions_scope, setup_scope], st)
    {cleanup, _, st} = phase(test.cleanup, [actions_scope, setup_scope], st)

    {%{test | load: load, setup: setup, actions: actions, verify: verify, cleanup: cleanup}, st}
  end

  # A phase is one scope over the scopes that reach it (C136).
  defp phase(nil, _base, st), do: {nil, %{}, st}

  defp phase(%AST.Phase{kind: kind} = phase, base, st) do
    ctx = %{@no_context | phase: kind}
    {statements, st} = statements(phase.statements, ctx, %{st | scopes: [%{} | base]})
    {%{phase | statements: statements}, hd(st.scopes), %{st | scopes: []}}
  end

  # ---------- Names (C149) ----------

  defp duplicates(ast, st) do
    curves =
      for load <- [ast.load | Enum.map(ast.tests, & &1.load)],
          load != nil,
          %AST.Curves{definitions: definitions} <- load.settings,
          definition <- definitions,
          do: definition

    st
    |> duplicate(ast.tests, "Test")
    |> duplicate(ast.functions || [], "fn")
    |> duplicate(curves, "curve")
  end

  defp duplicate(st, nodes, what) do
    {st, _seen} =
      Enum.reduce(nodes, {st, %{}}, fn node, {st, seen} ->
        case Map.fetch(seen, node.name) do
          {:ok, first} ->
            {error(st, node, "duplicate #{what} #{node.name} (first at #{position(first)}) (C149)"), seen}

          :error ->
            {st, Map.put(seen, node.name, node)}
        end
      end)

    st
  end

  # ---------- Functions (C150) ----------

  defp signature(%AST.FnDeclaration{} = fn_node, st) do
    {params, st} = Enum.map_reduce(fn_node.params, st, &resolve(&1.type, &2))
    {return, st} = resolve(fn_node.return_type, st)
    {{:fn, params, return}, st}
  end

  defp function({%AST.FnDeclaration{name: name} = fn_node, {:fn, params, return}}, st) do
    ctx = %{@no_context | phase: :function, fn: name, return: return}

    st =
      fn_node.params
      |> Enum.zip(params)
      |> Enum.reduce(%{st | scopes: [%{}]}, fn {param, type}, st ->
        declare(st, param, param.name, type, false, ctx)
      end)

    {statements, st} = statements(fn_node.body.statements, ctx, st)
    st = %{st | scopes: []}

    st =
      if return == :unit or returns?(statements) do
        st
      else
        error(st, fn_node, "fn #{name} must return #{format(return, st)} on every path (C150)")
      end

    {%{fn_node | body: %{fn_node.body | statements: statements}}, st}
  end

  defp returns?(statements) when is_list(statements), do: Enum.any?(statements, &returns_statement?/1)

  defp returns_statement?(%AST.Return{}), do: true

  defp returns_statement?(%AST.If{then: then, else: other}) when other != nil,
    do: returns_statement?(then) and returns_statement?(other)

  defp returns_statement?(%AST.Block{statements: statements}), do: returns?(statements)

  defp returns_statement?(%AST.MatchStatement{match: %AST.Match{arms: arms}}),
    do: covers_every_case?(arms) and Enum.all?(arms, &returns_statement?(&1.body))

  defp returns_statement?(_statement), do: false

  # The fns that read a metric, directly or through another fn (C146).
  defp metric_fns(st) do
    grown =
      for {name, called} <- st.fn_calls,
          Enum.any?(called, &MapSet.member?(st.fn_metrics, &1)),
          into: st.fn_metrics,
          do: name

    if MapSet.equal?(grown, st.fn_metrics), do: grown, else: metric_fns(%{st | fn_metrics: grown})
  end

  # ---------- Load ----------

  defp load(nil, st), do: {nil, st}

  defp load(%AST.Load{settings: settings} = load, st) do
    definitions = for %AST.Curves{definitions: definitions} <- settings, d <- definitions, do: d
    curves = Map.new(definitions, &{&1.name, length(&1.params)})

    {settings, st} = Enum.map_reduce(settings, %{st | curves: curves, curve_calls: %{}}, &load_setting/2)

    st =
      Enum.reduce(definitions, st, fn definition, st ->
        if curve_reaches?(definition.name, definition.name, st, MapSet.new()) do
          error(
            st,
            definition,
            "curve #{definition.name} calls itself, directly or through another curve (C56)"
          )
        else
          st
        end
      end)

    {%{load | settings: settings}, st}
  end

  defp curve_reaches?(from, name, st, seen) do
    Enum.any?(Map.get(st.curve_calls, from, []), fn called ->
      called == name or
        (not MapSet.member?(seen, called) and
           curve_reaches?(called, name, st, MapSet.put(seen, called)))
    end)
  end

  defp load_setting(%AST.Curves{definitions: definitions} = curves, st) do
    {definitions, st} = Enum.map_reduce(definitions, st, &curve_definition/2)
    {%{curves | definitions: definitions}, st}
  end

  defp load_setting(%AST.Stages{stages: stages} = setting, st) do
    {stages, st} = Enum.map_reduce(stages, st, &stage/2)
    {%{setting | stages: stages}, st}
  end

  defp load_setting(%AST.Distribution{entries: entries} = distribution, st) do
    st =
      Enum.reduce(entries, st, fn entry, st ->
        st |> known_target(entry, entry.target) |> takes_requests(entry, entry.target, "distribution")
      end)

    {distribution, st}
  end

  defp load_setting(%AST.StopIf{condition: condition} = stop_if, st) do
    {condition, st} = condition(condition, %{@no_context | phase: :stop_if}, st)
    {%{stop_if | condition: condition}, st}
  end

  defp load_setting(setting, st), do: {setting, st}

  # A curve's first parameter is the time (C28), and all are plain numbers (C18).
  defp curve_definition(%AST.CurveDefinition{name: name, params: params} = definition, st) do
    ctx = %{@no_context | phase: :curve, curve: name}

    st =
      case params do
        [] -> error(st, definition, "curve #{name} needs a parameter for the time (C28)")
        _ -> st
      end

    st = Enum.reduce(params, %{st | scopes: [%{}]}, &declare(&2, definition, &1, :float, false, ctx))
    {body, st} = checked(definition.body, :float, ctx, st)
    {%{definition | body: body}, %{st | scopes: []}}
  end

  defp stage(%AST.RampStage{curve: %AST.CurveRef{} = curve} = stage, st) do
    {curve, st} = curve_ref(curve, st)
    {%{stage | curve: curve}, st}
  end

  defp stage(stage, st), do: {stage, st}

  defp curve_ref(%AST.CurveRef{name: name} = curve, st) do
    ctx = %{@no_context | phase: :curve}
    given = curve.args || []
    {args, st} = Enum.map_reduce(given, st, &checked(&1, :float, ctx, &2))

    st =
      case st.curves[name] || @curve_arity[name] do
        nil ->
          error(st, curve, "unknown curve #{name} (C25)")

        arity when arity == length(given) + 1 ->
          st

        arity ->
          error(
            st,
            curve,
            "curve #{name} takes #{count(max(arity - 1, 0))} after the time, got #{length(given)} (C28)"
          )
      end

    {%{curve | args: if(curve.args, do: args)}, st}
  end

  # ---------- Statements ----------

  defp statements(statements, ctx, st), do: Enum.map_reduce(statements, st, &statement(&1, ctx, &2))

  defp statement(%AST.Let{} = node, ctx, st) do
    {annotation, st} = annotation(node.type, st)

    {value, st} =
      if annotation, do: checked(node.value, annotation, ctx, st), else: expr(node.value, nil, ctx, st)

    st = declare(st, node, node.name, annotation || value.type, node.mutable, ctx)
    {%{node | value: value}, st}
  end

  defp statement(%AST.Assign{name: name} = node, ctx, st) do
    entry = lookup(name, st)

    st =
      cond do
        entry == nil ->
          error(st, node, "unknown name #{name}")

        not entry.mutable ->
          error(st, node, "#{name} is not mutable; declare it with let mut (C76)")

        entry.phase == :setup and ctx.phase == :actions ->
          error(
            st,
            node,
            "Actions cannot assign to the Setup variable #{name}, since concurrent updates could be lost; " <>
              "collect values with add on a let mut list (C137)"
          )

        true ->
          st
      end

    {value, st} = checked(node.value, (entry && entry.type) || :unknown, ctx, st)
    {%{node | value: value}, st}
  end

  defp statement(%AST.Assert{} = node, ctx, st) do
    {condition, st} = condition(node.condition, ctx, st)
    {%{node | condition: condition}, st}
  end

  defp statement(%AST.Check{} = node, ctx, st) do
    {condition, st} = condition(node.condition, ctx, st)
    {%{node | condition: condition}, st}
  end

  defp statement(%AST.If{} = node, ctx, st) do
    {condition, st} = condition(node.condition, ctx, st)
    {then, st} = block(node.then, ctx, st)
    {other, st} = if node.else, do: statement(node.else, ctx, st), else: {nil, st}
    {%{node | condition: condition, then: then, else: other}, st}
  end

  defp statement(%AST.Block{} = node, ctx, st), do: block(node, ctx, st)

  defp statement(%AST.While{} = node, ctx, st) do
    {condition, st} = condition(node.condition, ctx, st)
    {body, st} = block(node.body, ctx, st)
    {%{node | condition: condition, body: body}, st}
  end

  defp statement(%AST.For{} = node, ctx, st) do
    {iterable, st} = expr(node.iterable, nil, ctx, st)
    {item, st} = item(iterable, st)

    scoped(st, fn st ->
      st = declare(st, node, node.var, item, false, ctx)
      {statements, st} = statements(node.body.statements, ctx, st)
      {%{node | iterable: iterable, body: %{node.body | statements: statements}}, st}
    end)
  end

  defp statement(%AST.Return{value: nil} = node, %{return: return}, st) do
    if return in [nil, :unit, :unknown] do
      {node, st}
    else
      {node, error(st, node, "return needs a value of type #{format(return, st)}")}
    end
  end

  defp statement(%AST.Return{} = node, ctx, st) do
    {value, st} = checked(node.value, ctx.return || :unknown, ctx, st)
    {%{node | value: value}, st}
  end

  defp statement(%AST.ExpressionStatement{} = node, ctx, st) do
    {expression, st} = expr(node.expression, nil, ctx, st)
    {%{node | expression: expression}, st}
  end

  defp statement(%AST.MatchStatement{} = node, ctx, st) do
    {match, st} = match(node.match, nil, :statement, ctx, st)
    {%{node | match: match}, st}
  end

  defp block(%AST.Block{} = block, ctx, st) do
    scoped(st, fn st ->
      {statements, st} = statements(block.statements, ctx, st)
      {%{block | statements: statements}, st}
    end)
  end

  defp condition(node, ctx, st), do: checked(node, :bool, ctx, st)

  # ---------- Match (C75, C148) ----------

  defp match(%AST.Match{} = node, expected, mode, ctx, st) do
    {subject, st} = expr(node.subject, nil, ctx, st)
    {arms, st} = Enum.map_reduce(node.arms, st, &arm(&1, subject.type, expected, ctx, &2))
    node = %{node | subject: subject, arms: arms}

    case mode do
      :statement ->
        {%{node | type: :unit}, st}

      :value ->
        {type, st} = arm_type(arms, st)

        st =
          if covers_every_case?(arms) do
            st
          else
            error(st, node, "a match used as a value must cover every case, e.g. end with _ (C148)")
          end

        {%{node | type: type}, st}
    end
  end

  defp arm(%AST.MatchArm{} = arm, subject, expected, ctx, st) do
    scoped(st, fn st ->
      {pattern, st} = pattern(arm.pattern, subject, ctx, st)
      {guard, st} = if arm.guard, do: condition(arm.guard, ctx, st), else: {nil, st}
      {body, st} = arm_body(arm.body, expected, ctx, st)
      {%{arm | pattern: pattern, guard: guard, body: body}, st}
    end)
  end

  defp arm_body(%AST.Block{} = body, _expected, ctx, st), do: block(body, ctx, st)
  defp arm_body(body, expected, ctx, st), do: expr(body, expected, ctx, st)

  defp pattern(%AST.LiteralPattern{} = pattern, subject, ctx, st) do
    {literal, st} = expr(pattern.literal, nil, ctx, st)
    {fits, st} = assign(literal.type, subject, st)

    st =
      if fits do
        st
      else
        error(
          st,
          pattern,
          "a pattern of type #{format(literal.type, st)} cannot match a value of type #{format(subject, st)} (C148)"
        )
      end

    {%{pattern | literal: literal}, st}
  end

  defp pattern(%AST.BindPattern{} = pattern, subject, ctx, st),
    do: {pattern, declare(st, pattern, pattern.name, subject, false, ctx)}

  defp pattern(pattern, _subject, _ctx, st), do: {pattern, st}

  defp arm_type(arms, st) do
    [first | rest] = arms

    Enum.reduce(rest, {body_type(first), st}, fn arm, {type, st} ->
      case join(type, body_type(arm), st) do
        {nil, st} ->
          message =
            "all arms of a match used as a value must give one type, " <>
              "got #{format(type, st)} and #{format(body_type(arm), st)} (C148)"

          {type, error(st, arm, message)}

        {joined, st} ->
          {joined, st}
      end
    end)
  end

  defp body_type(%AST.MatchArm{body: %AST.Block{}}), do: :unit
  defp body_type(%AST.MatchArm{body: body}), do: body.type

  defp covers_every_case?(arms) do
    literals =
      for %AST.MatchArm{guard: nil, pattern: %AST.LiteralPattern{literal: literal}} <- arms, do: literal

    bools = for %AST.BoolLiteral{value: value} <- literals, do: value

    catch_all?(List.last(arms)) or (true in bools and false in bools)
  end

  defp catch_all?(%AST.MatchArm{guard: nil, pattern: %AST.WildcardPattern{}}), do: true
  defp catch_all?(%AST.MatchArm{guard: nil, pattern: %AST.BindPattern{}}), do: true
  defp catch_all?(_arm), do: false

  # ---------- Expressions ----------

  # `expected` is the type the context asks for, or nil. Only the expressions
  # that take their type from context read it; `checked/4` compares the rest.
  defp checked(node, expected, ctx, st) do
    {node, st} = expr(node, expected, ctx, st)
    {node, expect(st, node, expected)}
  end

  defp expect(st, node, expected) do
    case assign(node.type, expected, st) do
      {true, st} -> st
      {false, st} -> error(st, node, "expected #{format(expected, st)}, got #{format(node.type, st)}")
    end
  end

  defp expr(%AST.Var{name: name} = node, _expected, ctx, st) do
    entry = lookup(name, st)

    cond do
      entry ->
        {%{node | type: entry.type}, st}

      Map.has_key?(st.fns, name) ->
        {%{node | type: st.fns[name]}, use_fn(st, node, name, ctx)}

      name in @constants ->
        {%{node | type: :float}, st}

      name in @math ->
        {%{node | type: {:fn, [:float], :float}}, st}

      name in ["sut", "loadGenerator"] and ctx.phase != :curve ->
        {%{node | type: :unknown}, error(st, node, "#{name} is not a value; use #{usage(name)}")}

      true ->
        {%{node | type: :unknown}, error(st, node, "unknown name #{name}")}
    end
  end

  defp expr(%AST.Member{} = node, _expected, ctx, st), do: member(node, ctx, st)
  defp expr(%AST.Call{} = node, _expected, ctx, st), do: call(node, ctx, st)

  defp expr(%AST.Index{} = node, _expected, ctx, st) do
    {object, st} = expr(node.object, nil, ctx, st)
    {index, st} = expr(node.index, nil, ctx, st)
    node = %{node | object: object, index: index}

    case opaque(object.type, st) do
      {:list, item} ->
        {%{node | type: item}, expect(st, index, :int)}

      :json ->
        if opaque(index.type, st) in [:int, :string, :json, :unknown] do
          {%{node | type: :json}, st}
        else
          message = "a JSON value is indexed by a String or an Int, not #{format(index.type, st)} (C68)"
          {%{node | type: :json}, error(st, index, message)}
        end

      :unknown ->
        {%{node | type: :unknown}, st}

      type ->
        {%{node | type: :unknown}, error(st, node, "#{format(type, st)} cannot be indexed (C68)")}
    end
  end

  defp expr(%AST.Binary{op: op} = node, _expected, ctx, st) when op in [:&&, :||] do
    {left, st} = condition(node.left, ctx, st)
    {right, st} = condition(node.right, ctx, st)
    {%{node | left: left, right: right, type: :bool}, st}
  end

  defp expr(%AST.Binary{op: op} = node, _expected, ctx, st) when op in [:==, :!=] do
    {left, st} = expr(node.left, nil, ctx, st)
    {right, st} = expr(node.right, nil, ctx, st)
    {same, st} = assign(left.type, right.type, st)
    {same, st} = if same, do: {true, st}, else: assign(right.type, left.type, st)
    st = if same, do: st, else: operator_error(st, node, left, right, "C153")
    {%{node | left: left, right: right, type: :bool}, st}
  end

  defp expr(%AST.Binary{op: op} = node, _expected, ctx, st) when op in [:<, :<=, :>, :>=] do
    {left, st} = expr(node.left, nil, ctx, st)
    {right, st} = expr(node.right, nil, ctx, st)

    st =
      if ordered?(opaque(left.type, st), opaque(right.type, st)) do
        st
      else
        operator_error(st, node, left, right, "C153")
      end

    {%{node | left: left, right: right, type: :bool}, st}
  end

  defp expr(%AST.Binary{op: op} = node, _expected, ctx, st) do
    {left, st} = expr(node.left, nil, ctx, st)
    {right, st} = expr(node.right, nil, ctx, st)
    node = %{node | left: left, right: right}

    case arithmetic(op, opaque(left.type, st), opaque(right.type, st)) do
      nil -> {%{node | type: :unknown}, operator_error(st, node, left, right, "C142")}
      type -> {%{node | type: type}, st}
    end
  end

  defp expr(%AST.Unary{op: :!} = node, _expected, ctx, st) do
    {operand, st} = condition(node.operand, ctx, st)
    {%{node | operand: operand, type: :bool}, st}
  end

  defp expr(%AST.Unary{} = node, _expected, ctx, st) do
    {operand, st} = expr(node.operand, nil, ctx, st)
    type = opaque(operand.type, st)

    if type in @numbers or type in @units or type in [:json, :unknown] do
      {%{node | operand: operand, type: operand.type}, st}
    else
      message = "unary - needs a number or a unit value, got #{format(operand.type, st)} (C147)"
      {%{node | operand: operand, type: :unknown}, error(st, node, message)}
    end
  end

  defp expr(%AST.Lambda{} = node, expected, ctx, st), do: lambda(node, expected, ctx, st)
  defp expr(%AST.ListOperation{} = node, _expected, ctx, st), do: list_operation(node, ctx, st)
  defp expr(%AST.Metric{} = node, _expected, ctx, st), do: metric(node, ctx, st)
  defp expr(%AST.Match{} = node, expected, ctx, st), do: match(node, expected, :value, ctx, st)

  # Inside JSON every value goes to the JSON form (C67, C140).
  defp expr(%AST.JsonObject{members: members} = node, _expected, ctx, st) do
    {members, st} =
      Enum.map_reduce(members, st, fn member, st ->
        {value, st} = json_value(member.value, ctx, st)
        {%{member | value: value}, st}
      end)

    {%{node | members: members, type: :json}, st}
  end

  defp expr(%AST.JsonArray{} = node, expected, ctx, st) do
    case expected && walk(expected, st) do
      {:list, item} = type ->
        {items, st} = Enum.map_reduce(node.items, st, &checked(&1, item, ctx, &2))
        {%{node | items: items, type: type}, st}

      :json ->
        {items, st} = Enum.map_reduce(node.items, st, &json_value(&1, ctx, &2))
        {%{node | items: items, type: :json}, st}

      _ ->
        {items, st} = Enum.map_reduce(node.items, st, &expr(&1, nil, ctx, &2))
        {type, st} = list_type(items, st)
        {%{node | items: items, type: type}, st}
    end
  end

  defp expr(%AST.Null{} = node, _expected, _ctx, st), do: {%{node | type: :json}, st}
  defp expr(%AST.Http{} = node, _expected, _ctx, st), do: {%{node | type: :unknown}, st}

  defp expr(%AST.NumberLiteral{value: value} = node, _e, _c, st) when is_integer(value),
    do: {%{node | type: :int}, st}

  defp expr(%AST.NumberLiteral{} = node, _e, _c, st), do: {%{node | type: :float}, st}
  defp expr(%AST.TimeLiteral{} = node, _e, _c, st), do: {%{node | type: :time}, st}
  defp expr(%AST.EnergyLiteral{} = node, _e, _c, st), do: {%{node | type: :energy}, st}
  defp expr(%AST.PowerLiteral{} = node, _e, _c, st), do: {%{node | type: :power}, st}
  defp expr(%AST.CarbonLiteral{} = node, _e, _c, st), do: {%{node | type: :carbon}, st}
  defp expr(%AST.UsersLiteral{} = node, _e, _c, st), do: {%{node | type: :users}, st}
  defp expr(%AST.PercentageLiteral{} = node, _e, _c, st), do: {%{node | type: :percentage}, st}
  defp expr(%AST.StringLiteral{} = node, _e, _c, st), do: {%{node | type: :string}, st}
  defp expr(%AST.BoolLiteral{} = node, _e, _c, st), do: {%{node | type: :bool}, st}

  defp json_value(node, ctx, st) do
    {node, st} = expr(node, :json, ctx, st)

    if json_form?(node.type, st) do
      {node, st}
    else
      {node, error(st, node, "a value of type #{format(node.type, st)} has no JSON form (C140)")}
    end
  end

  # A list of one type, or Json when the items differ (C140).
  defp list_type([], st), do: fresh(st, &{:list, &1})

  defp list_type([first | rest] = items, st) do
    {type, st} =
      Enum.reduce_while(rest, {first.type, st}, fn item, {type, st} ->
        case item_join(type, item.type, st) do
          {nil, st} -> {:halt, {nil, st}}
          result -> {:cont, result}
        end
      end)

    cond do
      type != nil -> {{:list, type}, st}
      Enum.all?(items, &json_form?(&1.type, st)) -> {:json, st}
      true -> {:unknown, error(st, first, "the items of this list have no common type (C140)")}
    end
  end

  defp item_join(left, right, st) do
    if walk(left, st) == :json == (walk(right, st) == :json), do: join(left, right, st), else: {nil, st}
  end

  # ---------- Members (C109, C110, C112, C143) ----------

  defp member(%AST.Member{object: %AST.Var{name: "sut"}, name: name} = node, ctx, st) do
    if lookup("sut", st) || ctx.phase == :curve do
      value_member(node, ctx, st)
    else
      case name do
        name when is_map_key(@machine_metrics, name) ->
          {%{node | type: :unknown}, error(st, node, "sut.#{name} is read with .mean() or .max() (C109)")}

        "any" ->
          {%{node | type: :target}, any_target(st, node, ctx)}

        _ ->
          {%{node | type: :target}, known_target(st, node, name)}
      end
    end
  end

  defp member(node, ctx, st), do: value_member(node, ctx, st)

  defp value_member(%AST.Member{name: name} = node, ctx, st) do
    {object, st} = expr(node.object, nil, ctx, st)
    node = %{node | object: object}

    case opaque(object.type, st) do
      :response when is_map_key(@response_members, name) ->
        {%{node | type: @response_members[name]}, st}

      :target when name == "http" or is_map_key(@machine_metrics, name) ->
        {%{node | type: :unknown}, error(st, node, "#{name} is not a value; use #{usage(name)}")}

      :json ->
        message = "a JSON value has no member #{name}; read it with [\"#{name}\"] (C68)"
        {%{node | type: :unknown}, error(st, node, message)}

      :unknown ->
        {%{node | type: :unknown}, st}

      type ->
        {%{node | type: :unknown}, error(st, node, "#{format(type, st)} has no member #{name}")}
    end
  end

  # sut.any picks a target per iteration, so it needs one (C168). In a fn the
  # calling phase is only known at run time.
  defp any_target(st, node, %{phase: phase}) when phase not in [:actions, :function],
    do: error(st, node, "sut.any picks a target per iteration, so it only works in Actions (C168)")

  defp any_target(%{distribution: false} = st, node, %{phase: :actions}),
    do: error(st, node, "sut.any needs a distribution in Load (C168)")

  defp any_target(st, _node, _ctx), do: st

  defp known_target(st, node, name) do
    if Map.has_key?(st.targets, name) do
      st
    else
      error(st, node, "unknown target #{name}; define it in Config or the external configuration (C143)")
    end
  end

  defp takes_requests(st, node, name, what) do
    case st.targets[name] do
      %{base_url: false} ->
        error(st, node, "#{what} needs a target with a baseUrl, and #{name} has none (C156)")

      _ ->
        st
    end
  end

  # The name in a direct sut.<target>. A Target value is only known at run time (C156).
  defp direct_target(%AST.Member{object: %AST.Var{name: "sut"}, name: name}, st) do
    if lookup("sut", st), do: nil, else: name
  end

  defp direct_target(_node, _st), do: nil

  # ---------- Calls ----------

  defp call(%AST.Call{callee: %AST.Var{name: name}} = node, ctx, st) do
    cond do
      lookup(name, st) -> call_value(node, ctx, st)
      ctx.phase == :curve and Map.has_key?(st.curves, name) -> call_curve(node, name, ctx, st)
      Map.has_key?(st.fns, name) -> call_fn(node, name, ctx, st)
      true -> call_builtin(node, name, ctx, st)
    end
  end

  defp call(%AST.Call{callee: %AST.Member{object: %AST.Http{}, name: method}} = node, ctx, st),
    do: http_call(node, method, ctx, st)

  defp call(
         %AST.Call{callee: %AST.Member{object: %AST.Member{name: "http"} = client, name: method}} = node,
         ctx,
         st
       ) do
    {object, st} = expr(client.object, nil, ctx, st)
    st = expect(st, object, :target)
    st = takes_requests(st, node, direct_target(object, st), "an http call")
    callee = %{node.callee | object: %{client | object: object}}
    http_call(%{node | callee: callee}, method, ctx, st)
  end

  defp call(%AST.Call{callee: %AST.Member{object: %AST.Member{name: name} = reading}} = node, ctx, st)
       when is_map_key(@machine_metrics, name),
       do: machine_reading(node, reading, ctx, st)

  defp call(%AST.Call{callee: %AST.Member{object: %AST.Member{name: name} = group}} = node, ctx, st)
       when is_map_key(@request_metrics, name) do
    if per_target?(group.object, ctx, st),
      do: target_metric(node, group, ctx, st),
      else: method(node, node.callee, ctx, st)
  end

  defp call(%AST.Call{callee: %AST.Member{} = callee} = node, ctx, st), do: method(node, callee, ctx, st)
  defp call(%AST.Call{} = node, ctx, st), do: call_value(node, ctx, st)

  defp call_value(%AST.Call{} = node, ctx, st) do
    {callee, st} = expr(node.callee, nil, ctx, st)
    node = %{node | callee: callee}

    case opaque(callee.type, st) do
      {:fn, params, return} ->
        {args, st} = arguments(node, params, ctx, st)
        {%{node | args: args, type: return}, st}

      :unknown ->
        {args, st} = Enum.map_reduce(node.args, st, &expr(&1, nil, ctx, &2))
        {%{node | args: args, type: :unknown}, st}

      type ->
        {args, st} = Enum.map_reduce(node.args, st, &expr(&1, nil, ctx, &2))
        {%{node | args: args, type: :unknown}, error(st, node, "#{format(type, st)} is not a function")}
    end
  end

  defp call_fn(%AST.Call{} = node, name, %{phase: phase} = ctx, st) when phase in [:curve, :stop_if] do
    {args, st} = Enum.map_reduce(node.args, st, &expr(&1, nil, ctx, &2))
    what = if phase == :curve, do: "a curve", else: "stopIf"
    {%{node | args: args, type: :unknown}, error(st, node, "#{what} cannot call fn #{name} (C152)")}
  end

  defp call_fn(%AST.Call{callee: callee} = node, name, ctx, st) do
    {:fn, params, return} = type = st.fns[name]
    st = use_fn(st, node, name, ctx)
    {args, st} = arguments(node, params, ctx, st)
    {%{node | callee: %{callee | type: type}, args: args, type: return}, st}
  end

  defp call_curve(%AST.Call{callee: callee} = node, name, ctx, st) do
    params = List.duplicate(:float, st.curves[name])
    calls = Map.update(st.curve_calls, ctx.curve, [name], &[name | &1])
    {args, st} = arguments(node, params, ctx, %{st | curve_calls: calls})
    type = {:fn, params, :float}
    {%{node | callee: %{callee | type: type}, args: args, type: :float}, st}
  end

  defp call_builtin(%AST.Call{callee: callee} = node, name, ctx, st) when name in @math do
    {args, st} = arguments(node, [:float], ctx, st)
    {%{node | callee: %{callee | type: {:fn, [:float], :float}}, args: args, type: :float}, st}
  end

  defp call_builtin(%AST.Call{} = node, name, ctx, st) when name in ["min", "max"] do
    {args, st} = Enum.map_reduce(node.args, st, &expr(&1, nil, ctx, &2))
    node = %{node | args: args}

    case args do
      [left, right] ->
        case limit_type(opaque(left.type, st), opaque(right.type, st)) do
          nil ->
            message = "#{name} takes two numbers or two values of one unit type (C144)"
            {%{node | type: :unknown}, error(st, node, message)}

          type ->
            {%{node | type: type}, st}
        end

      _ ->
        {%{node | type: :unknown}, error(st, node, "#{name} takes 2 arguments, got #{length(args)} (C144)")}
    end
  end

  defp call_builtin(%AST.Call{} = node, name, %{phase: :curve} = ctx, st) when name in ["range", "sleep"] do
    {args, st} = Enum.map_reduce(node.args, st, &expr(&1, nil, ctx, &2))
    {%{node | args: args, type: :unknown}, error(st, node, "a curve cannot call #{name} (C56, C152)")}
  end

  defp call_builtin(%AST.Call{} = node, "range", ctx, st) do
    {args, st} = arguments(node, [:int, :int], ctx, st)
    {%{node | args: args, type: {:list, :int}}, st}
  end

  defp call_builtin(%AST.Call{} = node, "sleep", ctx, st) do
    {args, st} = arguments(node, [:time], ctx, st)
    {%{node | args: args, type: :unit}, st}
  end

  defp call_builtin(%AST.Call{callee: %AST.Var{name: name} = callee} = node, _name, ctx, st) do
    {args, st} = Enum.map_reduce(node.args, st, &expr(&1, nil, ctx, &2))
    {%{node | callee: callee, args: args, type: :unknown}, error(st, callee, "unknown name #{name}")}
  end

  defp arguments(%AST.Call{args: args}, params, ctx, st) when length(args) == length(params) do
    args
    |> Enum.zip(params)
    |> Enum.map_reduce(st, fn {arg, param}, st -> checked(arg, param, ctx, st) end)
  end

  defp arguments(%AST.Call{args: args} = node, params, ctx, st) do
    {args_out, st} = Enum.map_reduce(args, st, &expr(&1, nil, ctx, &2))
    {args_out, error(st, node, "expected #{count(length(params))}, got #{length(args)}")}
  end

  defp limit_type(:json, type) when type in @numbers or type == :json, do: :json
  defp limit_type(type, :json) when type in @numbers, do: :json
  defp limit_type(left, right) when left in @numbers and right in @numbers, do: join_numbers(left, right)
  defp limit_type(type, type) when type in @ordered, do: type
  defp limit_type(:unknown, _right), do: :unknown
  defp limit_type(_left, :unknown), do: :unknown
  defp limit_type(_left, _right), do: nil

  defp join_numbers(:int, :int), do: :int
  defp join_numbers(_left, _right), do: :float

  # ---------- http (C112-C115, C123) ----------

  defp http_call(%AST.Call{args: args} = node, method, %{phase: phase} = ctx, st) do
    st =
      if phase in [:curve, :stop_if] do
        what = if phase == :curve, do: "a curve", else: "stopIf"
        error(st, node, "#{what} cannot make http calls (C152)")
      else
        st
      end

    {args, st} =
      args
      |> Enum.with_index()
      |> Enum.map_reduce(st, fn {arg, position}, st -> http_arg(arg, position, method, ctx, st) end)

    {%{node | args: args, type: :response}, st}
  end

  defp http_arg(arg, 0, _method, ctx, st), do: checked(arg, :string, ctx, st)
  defp http_arg(arg, 1, method, ctx, st) when method in @http_bodies, do: json_value(arg, ctx, st)
  defp http_arg(arg, _position, _method, ctx, st), do: checked(arg, :json, ctx, st)

  # ---------- Machine readings and metrics (C60, C109, C146, C154, C160, C161) ----------

  defp machine_reading(
         %AST.Call{callee: callee, args: args} = node,
         %AST.Member{name: metric} = reading,
         ctx,
         st
       ) do
    {source, st} = reading_source(reading.object, ctx, st)
    st = st |> readable(node, ctx) |> lists_metric(node, source, metric)

    st =
      if callee.name in ["mean", "max"] and args == [] do
        st
      else
        error(st, node, "#{metric} is read with .mean() or .max() (C109)")
      end

    node = %{node | callee: %{callee | object: %{reading | object: source}}}
    {%{node | type: @machine_metrics[metric]}, st}
  end

  defp reading_source(%AST.Var{name: name} = node, ctx, st) when name in ["sut", "loadGenerator"] do
    if lookup(name, st) || ctx.phase == :curve, do: target_value(node, ctx, st), else: {node, st}
  end

  defp reading_source(node, ctx, st), do: target_value(node, ctx, st)

  defp target_value(node, ctx, st), do: checked(node, :target, ctx, st)

  defp lists_metric(st, node, %AST.Var{name: "sut"}, metric) do
    if lookup("sut", st) || power_of_targets?(st, metric),
      do: st,
      else: error(st, node, "no target lists #{metric} in its metrics (C160)")
  end

  defp lists_metric(st, node, %AST.Var{name: "loadGenerator"}, metric) do
    if lookup("loadGenerator", st) || metric in @load_generator_metrics,
      do: st,
      else: error(st, node, "loadGenerator reads only cpu and mem (C160)")
  end

  defp lists_metric(st, node, source, metric) do
    name = direct_target(source, st)

    if name == nil or not Map.has_key?(st.targets, name) or metric in st.targets[name].metrics do
      st
    else
      error(st, node, "target #{name} does not list #{metric} in its metrics (C160)")
    end
  end

  defp power_of_targets?(st, metric), do: Enum.any?(st.targets, fn {_name, t} -> metric in t.metrics end)

  # A request metric per target (C176): the target is checked like the one of
  # an http call, since the metric reads the requests sent to it.
  defp metric(%AST.Metric{group: group, measurement: measurement, target: target} = node, ctx, st)
       when target != nil do
    {source, st} = target_value(target, ctx, st)

    st =
      st
      |> readable(node, ctx)
      |> live_totals_only(node, ctx)
      |> takes_requests(node, direct_target(source, st), "a request metric per target")
      |> percentile(node)

    {%{node | target: source, type: metric_type(group, measurement)}, st}
  end

  defp metric(%AST.Metric{group: group, measurement: measurement} = node, ctx, st) do
    st = st |> readable(node, ctx) |> percentile(node) |> energy_source(node)
    {%{node | type: metric_type(group, measurement)}, st}
  end

  # x.latency.p95() is a metric per target when x is a Target. sut alone is
  # the namespace, so sut.latency.p95() is one too, and rejected there.
  defp per_target?(%AST.Var{name: "sut"} = node, ctx, st) do
    if lookup("sut", st), do: target_typed?(node, ctx, st), else: true
  end

  defp per_target?(node, ctx, st), do: target_typed?(node, ctx, st)

  # Only the type is needed here: the object is checked again where it is used.
  defp target_typed?(node, ctx, st) do
    {object, _st} = expr(node, nil, ctx, st)
    object.type == :target
  end

  defp target_metric(%AST.Call{callee: callee, args: args} = node, %AST.Member{name: name} = group, ctx, st) do
    {group_name, measurements} = @request_metrics[name]
    measurement = callee.name

    cond do
      match?(%AST.Var{name: "sut"}, group.object) and lookup("sut", st) == nil ->
        message = "#{name}.#{measurement}() is already over all targets, without sut (C176)"
        {%{node | type: :unknown}, error(st, node, message)}

      measurement not in measurements ->
        message = "#{name} has no measurement #{measurement}; use #{Enum.join(measurements, ", ")} (C60)"
        {%{node | type: :unknown}, error(st, node, message)}

      true ->
        {argument, st} = metric_argument(measurement, args, node, st)

        metric = %AST.Metric{
          loc: node.loc,
          group: group_name,
          measurement: String.to_atom(measurement),
          argument: argument,
          target: group.object
        }

        metric(metric, ctx, st)
    end
  end

  defp metric_argument("percentile", [%AST.NumberLiteral{} = argument], _node, st), do: {argument, st}

  defp metric_argument("percentile", _args, node, st),
    do: {nil, error(st, node, "percentile takes one number from 0 to 100, e.g. percentile(99.9) (C154)")}

  defp metric_argument(_measurement, [], _node, st), do: {nil, st}

  defp metric_argument(measurement, _args, node, st),
    do: {nil, error(st, node, "#{measurement}() takes no arguments (C60)")}

  defp live_totals_only(st, node, %{phase: :stop_if}),
    do: error(st, node, "stopIf reads live totals, so it cannot read a metric per target (C58, C176)")

  defp live_totals_only(st, _node, _ctx), do: st

  defp percentile(st, %AST.Metric{
         measurement: :percentile,
         argument: %AST.NumberLiteral{value: value} = argument
       })
       when value > 100 do
    error(st, argument, "percentile takes a number from 0 to 100, got #{argument.raw} (C154)")
  end

  defp percentile(st, _metric), do: st

  defp energy_source(st, %AST.Metric{group: group} = node) when group in [:energy, :power, :carbon] do
    cond do
      not power_of_targets?(st, "power") ->
        error(st, node, "#{group} metrics need a target with power in its metrics (C161)")

      group == :carbon and AST.CarbonIntensity not in st.monitoring ->
        error(st, node, "carbon metrics need carbonIntensity in monitoring (C161)")

      true ->
        st
    end
  end

  defp energy_source(st, _metric), do: st

  defp metric_type(:latency, _measurement), do: :time
  defp metric_type(:throughput, _measurement), do: :float
  defp metric_type(:energy, _measurement), do: :energy
  defp metric_type(:power, _measurement), do: :power
  defp metric_type(:carbon, _measurement), do: :carbon
  defp metric_type(_group, :rate), do: :percentage
  defp metric_type(_group, _measurement), do: :int

  defp readable(st, node, %{phase: :setup}),
    do: error(st, node, "metrics cannot be read in Setup, where no load has run (C146)")

  defp readable(st, node, %{phase: :actions}),
    do: error(st, node, "metrics cannot be read in Actions, where a value would depend on timing (C146)")

  defp readable(st, node, %{phase: :curve}), do: error(st, node, "a curve cannot read metrics (C152)")

  defp readable(st, _node, %{phase: :function, fn: name}),
    do: %{st | fn_metrics: MapSet.put(st.fn_metrics, name)}

  defp readable(st, _node, _ctx), do: st

  defp use_fn(st, node, name, %{phase: phase}) when phase in [:setup, :actions] do
    if MapSet.member?(st.metric_fns, name) do
      where = if phase == :setup, do: "Setup", else: "Actions"
      error(st, node, "fn #{name} reads metrics, so it cannot be used in #{where} (C146)")
    else
      st
    end
  end

  defp use_fn(st, _node, name, %{fn: caller}) when caller != nil do
    %{st | fn_calls: Map.update(st.fn_calls, caller, [name], &[name | &1])}
  end

  defp use_fn(st, _node, _name, _ctx), do: st

  # ---------- Lists (C91, C134, C137, C140, C145) ----------

  # toString() works on every value with a text form, not only on lists (C177).
  defp method(%AST.Call{} = node, %AST.Member{name: "toString"} = callee, ctx, st) do
    {object, st} = expr(callee.object, nil, ctx, st)
    {args, st} = Enum.map_reduce(node.args, st, &expr(&1, nil, ctx, &2))
    node = %{node | callee: %{callee | object: object}, args: args, type: :string}
    type = opaque(object.type, st)

    cond do
      args != [] ->
        {node, error(st, node, "toString takes no arguments, got #{length(args)} (C177)")}

      type in @text_types ->
        {node, st}

      true ->
        {node, error(st, node, "#{format(type, st)} has no method toString (C177)")}
    end
  end

  defp method(%AST.Call{} = node, %AST.Member{name: name} = callee, ctx, st) do
    {object, st} = expr(callee.object, nil, ctx, st)
    node = %{node | callee: %{callee | object: object}}

    case opaque(object.type, st) do
      {:list, item} ->
        list_method(node, name, item, object, ctx, st)

      :json ->
        list_method(node, name, :json, object, ctx, st)

      :unknown ->
        {args, st} = Enum.map_reduce(node.args, st, &expr(&1, nil, ctx, &2))
        {%{node | args: args, type: :unknown}, st}

      type ->
        no_method(node, name, type, ctx, st)
    end
  end

  defp list_method(%AST.Call{args: []} = node, "length", _item, _object, _ctx, st),
    do: {%{node | type: :int}, st}

  defp list_method(%AST.Call{args: []} = node, "random", item, _object, _ctx, st),
    do: {%{node | type: item}, st}

  defp list_method(%AST.Call{args: [count]} = node, "random", item, _object, ctx, st) do
    {count, st} = checked(count, :int, ctx, st)
    {%{node | args: [count], type: {:list, item}}, st}
  end

  defp list_method(%AST.Call{args: [value]} = node, "contains", item, _object, ctx, st) do
    {value, st} = checked(value, item, ctx, st)
    {%{node | args: [value], type: :bool}, st}
  end

  defp list_method(%AST.Call{args: [value]} = node, "add", item, object, ctx, st) do
    st = added_to(st, object)
    {value, st} = checked(value, item, ctx, st)
    {%{node | args: [value], type: :unit}, st}
  end

  defp list_method(%AST.Call{args: args} = node, name, _item, _object, ctx, st)
       when name in ["length", "random", "contains", "add"] do
    {args_out, st} = Enum.map_reduce(args, st, &expr(&1, nil, ctx, &2))
    message = "#{name} takes #{expected_args(name)}, got #{length(args)} (C137, C145)"
    {%{node | args: args_out, type: :unknown}, error(st, node, message)}
  end

  defp list_method(node, name, item, _object, ctx, st),
    do: no_method(node, name, {:list, item}, ctx, st)

  defp expected_args("length"), do: "no arguments"
  defp expected_args("random"), do: "at most 1 argument"
  defp expected_args(_name), do: "1 argument"

  defp no_method(%AST.Call{} = node, name, type, ctx, st) do
    {args, st} = Enum.map_reduce(node.args, st, &expr(&1, nil, ctx, &2))
    {%{node | args: args, type: :unknown}, error(st, node, "#{format(type, st)} has no method #{name}")}
  end

  defp added_to(st, %AST.Var{name: name} = object) do
    case {lookup(name, st), opaque(object.type, st)} do
      {%{mutable: true}, {:list, _item}} -> st
      {_entry, :unknown} -> st
      _ -> error(st, object, "add needs a list declared with let mut, and #{name} is not one (C137)")
    end
  end

  defp added_to(st, object), do: error(st, object, "add needs a variable declared with let mut (C137)")

  defp list_operation(%AST.ListOperation{op: op} = node, ctx, st) do
    {receiver, st} = expr(node.receiver, nil, ctx, st)
    {item, st} = item(receiver, st)
    node = %{node | receiver: receiver}

    case op do
      :map ->
        {return, st} = fresh(st, & &1)
        {function, st} = function_value(node.function, {:fn, [item], return}, ctx, st)
        {%{node | function: function, type: {:list, return}}, st}

      :filter ->
        {function, st} = function_value(node.function, {:fn, [item], :bool}, ctx, st)
        {%{node | function: function, type: {:list, item}}, st}

      fold ->
        {init, st} = expr(node.init, nil, ctx, st)
        params = if fold == :foldr, do: [item, init.type], else: [init.type, item]
        {function, st} = function_value(node.function, {:fn, params, init.type}, ctx, st)
        {%{node | init: init, function: function, type: init.type}, st}
    end
  end

  defp function_value(%AST.Lambda{} = lambda, expected, ctx, st), do: lambda(lambda, expected, ctx, st)

  # A named fn: the list items go in as arguments, so Json items convert (C141).
  defp function_value(node, {:fn, params, return} = expected, ctx, st) do
    {node, st} = expr(node, nil, ctx, st)

    case opaque(node.type, st) do
      {:fn, given, given_return} when length(given) == length(params) ->
        {fits, st} =
          params
          |> Enum.zip(given)
          |> Enum.reduce({true, st}, fn {param, wanted}, {fits, st} ->
            {ok, st} = assign(param, wanted, st)
            {fits and ok, st}
          end)

        {returned, st} = assign(given_return, return, st)

        if fits and returned do
          {node, st}
        else
          {node, mismatch(st, node, expected)}
        end

      :unknown ->
        {node, st}

      _ ->
        {node, mismatch(st, node, expected)}
    end
  end

  defp mismatch(st, node, expected),
    do: error(st, node, "expected #{format(expected, st)}, got #{format(node.type, st)}")

  defp item(node, st) do
    case opaque(node.type, st) do
      {:list, item} -> {item, st}
      :json -> {:json, st}
      :unknown -> {:unknown, st}
      type -> {:unknown, error(st, node, "expected a list, got #{format(type, st)}")}
    end
  end

  # ---------- Lambdas (C90, C151) ----------

  defp lambda(%AST.Lambda{params: params} = node, expected, ctx, st) do
    {context, return, st} = lambda_context(node, expected, st)

    {types, st} =
      params
      |> Enum.zip(context)
      |> Enum.map_reduce(st, fn {param, from_context}, st -> lambda_param(param, from_context, st) end)

    scoped(st, fn st ->
      st =
        params
        |> Enum.zip(types)
        |> Enum.reduce(st, fn {param, type}, st -> declare(st, param, param.name, type, false, ctx) end)

      {body, st} = if return, do: checked(node.body, return, ctx, st), else: expr(node.body, nil, ctx, st)
      {%{node | body: body, type: {:fn, types, return || body.type}}, st}
    end)
  end

  defp lambda_context(%AST.Lambda{params: params} = node, expected, st) do
    none = List.duplicate(nil, length(params))

    case expected && walk(expected, st) do
      {:fn, types, return} when length(types) == length(params) ->
        {types, return, st}

      {:fn, types, return} ->
        message = "this lambda takes #{length(params)} parameters, expected #{length(types)}"
        {none, return, error(st, node, message)}

      _ ->
        {none, nil, st}
    end
  end

  defp lambda_param(%AST.LambdaParam{type: nil, name: name} = param, nil, st) do
    {:unknown,
     error(st, param, "lambda parameter #{name} needs a type here: \\(#{name}: Type) -> ... (C151)")}
  end

  defp lambda_param(%AST.LambdaParam{type: nil}, from_context, st), do: {from_context, st}

  defp lambda_param(%AST.LambdaParam{type: type} = param, from_context, st) do
    {written, st} = resolve(type, st)

    if from_context == nil do
      {written, st}
    else
      {fits, st} = assign(from_context, written, st)

      if fits do
        {written, st}
      else
        message =
          "lambda parameter #{param.name} is #{format(written, st)}, expected #{format(from_context, st)}"

        {written, error(st, param, message)}
      end
    end
  end

  # ---------- Operators (C142, C145, C153) ----------

  defp arithmetic(_op, :unknown, _right), do: :unknown
  defp arithmetic(_op, _left, :unknown), do: :unknown
  defp arithmetic(:+, :string, right) when right in [:string, :json], do: :string
  defp arithmetic(:+, :json, :string), do: :string
  defp arithmetic(_op, :json, right) when right in @numbers or right == :json, do: :json
  defp arithmetic(_op, left, :json) when left in @numbers, do: :json
  defp arithmetic(op, :int, :int) when op in [:+, :-, :*], do: :int
  defp arithmetic(_op, left, right) when left in @numbers and right in @numbers, do: :float
  defp arithmetic(op, unit, unit) when op in [:+, :-] and unit in @units, do: unit
  defp arithmetic(:/, unit, unit) when unit in @units, do: :float
  defp arithmetic(:/, :energy, :time), do: :power
  defp arithmetic(:*, :power, :time), do: :energy
  defp arithmetic(:*, :time, :power), do: :energy
  defp arithmetic(:*, unit, number) when unit in @units and (number in @numbers or number == :json), do: unit
  defp arithmetic(:*, number, unit) when unit in @units and (number in @numbers or number == :json), do: unit
  defp arithmetic(:/, unit, number) when unit in @units and (number in @numbers or number == :json), do: unit
  defp arithmetic(_op, _left, _right), do: nil

  defp ordered?(:unknown, _right), do: true
  defp ordered?(_left, :unknown), do: true
  defp ordered?(left, right) when left in @numbers and right in @numbers, do: true
  defp ordered?(:json, right) when right in @numbers or right == :json, do: true
  defp ordered?(left, :json) when left in @numbers, do: true
  defp ordered?(type, type) when type in @ordered, do: true
  defp ordered?(_left, _right), do: false

  defp operator_error(st, %AST.Binary{op: op} = node, left, right, decision) do
    error(
      st,
      node,
      "#{op} cannot be used on #{format(left.type, st)} and #{format(right.type, st)} (#{decision})"
    )
  end

  # ---------- Types (C138-C141) ----------

  defp annotation(nil, st), do: {nil, st}
  defp annotation(%AST.Type{} = type, st), do: resolve(type, st)

  defp resolve(%AST.Type{name: "List", args: [item]}, st) do
    {item, st} = resolve(item, st)
    {{:list, item}, st}
  end

  defp resolve(%AST.Type{name: "List"} = type, st),
    do: {:unknown, error(st, type, "List takes one type argument, e.g. List<Int> (C72)")}

  defp resolve(%AST.Type{name: "Fn", args: [_ | _] = args}, st) do
    {types, st} = Enum.map_reduce(args, st, &resolve/2)
    {params, [return]} = Enum.split(types, -1)
    {{:fn, params, return}, st}
  end

  defp resolve(%AST.Type{name: "Fn"} = type, st),
    do: {:unknown, error(st, type, "Fn needs at least its return type, e.g. Fn<Int, Bool> (C151)")}

  defp resolve(%AST.Type{name: "Number"} = type, st),
    do: {:unknown, error(st, type, "Number is not a type name; use Int or Float (C139)")}

  defp resolve(%AST.Type{name: name, args: []} = type, st) do
    case @types do
      %{^name => resolved} -> {resolved, st}
      _ -> {:unknown, error(st, type, "unknown type #{name} (C138)")}
    end
  end

  defp resolve(%AST.Type{name: name} = type, st) when is_map_key(@types, name),
    do: {:unknown, error(st, type, "#{name} takes no type arguments (C138)")}

  defp resolve(%AST.Type{name: name} = type, st),
    do: {:unknown, error(st, type, "unknown type #{name} (C138)")}

  defp fresh(st, build) do
    {build.({:var, st.next}), %{st | next: st.next + 1}}
  end

  defp walk({:var, id} = var, st) do
    case st.subst do
      %{^id => type} -> walk(type, st)
      _ -> var
    end
  end

  defp walk(type, _st), do: type

  defp bind(id, type, st), do: %{st | subst: Map.put(st.subst, id, type)}

  # The type for operators, which treat an unfilled type variable as unknown.
  defp opaque(type, st) do
    case walk(type, st) do
      {:var, _id} -> :unknown
      resolved -> resolved
    end
  end

  # Can a value of type `from` go where `to` is expected?
  defp assign(from, to, st) do
    case {walk(from, st), walk(to, st)} do
      {same, same} -> {true, st}
      {:unknown, _to} -> {true, st}
      {_from, :unknown} -> {true, st}
      {{:var, id}, type} -> {true, bind(id, type, st)}
      {type, {:var, id}} -> {true, bind(id, type, st)}
      {:int, :float} -> {true, st}
      {:json, to} when to in @conversions -> {true, st}
      {:json, {:list, _item}} -> {true, st}
      {type, :json} -> {json_form?(type, st), st}
      {left, right} -> unify(left, right, st)
    end
  end

  defp unify(left, right, st) do
    case {walk(left, st), walk(right, st)} do
      {same, same} ->
        {true, st}

      {:unknown, _right} ->
        {true, st}

      {_left, :unknown} ->
        {true, st}

      {{:var, id}, type} ->
        {true, bind(id, type, st)}

      {type, {:var, id}} ->
        {true, bind(id, type, st)}

      {{:list, left}, {:list, right}} ->
        unify(left, right, st)

      {{:fn, left, left_return}, {:fn, right, right_return}} when length(left) == length(right) ->
        Enum.reduce(Enum.zip(left ++ [left_return], right ++ [right_return]), {true, st}, fn {a, b},
                                                                                             {ok, st} ->
          {same, st} = unify(a, b, st)
          {ok and same, st}
        end)

      _ ->
        {false, st}
    end
  end

  # The common type of two values, or nil.
  defp join(left, right, st) do
    case {walk(left, st), walk(right, st)} do
      {same, same} ->
        {same, st}

      {:unknown, type} ->
        {type, st}

      {type, :unknown} ->
        {type, st}

      {left, right} when left in @numbers and right in @numbers ->
        {:float, st}

      {:json, type} ->
        if json_form?(type, st), do: {:json, st}, else: {nil, st}

      {type, :json} ->
        if json_form?(type, st), do: {:json, st}, else: {nil, st}

      {left, right} ->
        case unify(left, right, st) do
          {true, st} -> {left, st}
          {false, st} -> {nil, st}
        end
    end
  end

  defp json_form?(type, st) do
    case walk(type, st) do
      {:list, item} -> json_form?(item, st)
      {:var, _id} -> true
      resolved -> resolved in [:int, :float, :bool, :string, :json, :unknown]
    end
  end

  # ---------- Scopes (C136, C149) ----------

  defp scoped(st, fun) do
    {result, st} = fun.(%{st | scopes: [%{} | st.scopes]})
    {result, %{st | scopes: tl(st.scopes)}}
  end

  defp declare(%{scopes: [scope | rest]} = st, node, name, type, mutable, ctx) do
    st =
      case scope do
        %{^name => first} ->
          error(st, node, "#{name} is already declared in this scope, at #{position(first)} (C149)")

        _ ->
          st
      end

    entry = %{type: type, mutable: mutable, phase: ctx.phase, loc: node.loc}
    %{st | scopes: [Map.put(scope, name, entry) | rest]}
  end

  defp lookup(name, st), do: Enum.find_value(st.scopes, &Map.get(&1, name))

  # ---------- Result ----------

  # Fills in what the type variables stood for, so no variable leaves the module.
  defp finish(%{__struct__: _} = node, st) do
    node
    |> Map.from_struct()
    |> Enum.reduce(node, fn
      {:type, type}, node when not is_struct(type) -> %{node | type: final(type, st)}
      {key, value}, node -> %{node | key => finish(value, st)}
    end)
  end

  defp finish(list, st) when is_list(list), do: Enum.map(list, &finish(&1, st))
  defp finish(other, _st), do: other

  defp final(nil, _st), do: nil

  defp final(type, st) do
    case walk(type, st) do
      {:var, _id} -> :unknown
      {:list, item} -> {:list, final(item, st)}
      {:fn, params, return} -> {:fn, Enum.map(params, &final(&1, st)), final(return, st)}
      resolved -> resolved
    end
  end

  # ---------- Helpers ----------

  defp usage("sut"), do: "sut.<target>"
  defp usage("loadGenerator"), do: "loadGenerator.cpu.mean() or .max()"
  defp usage("http"), do: "http.<method>(...)"
  defp usage(metric), do: "#{metric}.mean() or #{metric}.max()"

  defp format(type, st) do
    case walk(type, st) do
      {:list, item} -> "List<#{format(item, st)}>"
      {:fn, params, return} -> "Fn<#{Enum.map_join(params ++ [return], ", ", &format(&1, st))}>"
      {:var, _id} -> "?"
      :unknown -> "?"
      name -> @type_names[name]
    end
  end

  defp count(1), do: "1 argument"
  defp count(number), do: "#{number} arguments"

  defp position(%{loc: {line, column}}), do: "#{line}:#{column}"

  defp error(st, %{loc: {line, column}}, message) do
    error = %Error{stage: :semantic, message: message, line: line, column: column}
    %{st | errors: [error | st.errors]}
  end
end
