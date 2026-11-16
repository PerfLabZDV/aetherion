defmodule Aetherion.Interpreter do
  @moduledoc """
  Runs the statements of a phase over the typed AST.

  `env` is a list of scopes, innermost first; each scope maps names to values.
  `ctx` holds the run (`rt`), the Test (`test`), the phase, and the virtual user
  and iteration. These throw `{:perflang, reason}` to leave a phase:

    * `:end_iteration`: a failed assert in Actions (C116).
    * `:stop_phase`: a failed assert in Setup, or a failed assert with no value
      in Setup, Verify or Cleanup (C116, C141).
    * `:user_stopped`: the run ended for this virtual user (C169).

  The Analyzer has checked names and types, so a value that does not fit here
  can only be Json, which is checked when it is used (C141).
  """

  alias PerfLang.AST
  alias Aetherion.{Cells, Http, Monitor, Recorder, Source, Values}

  @machine_metrics ["cpu", "mem", "disk", "net", "gpu", "power"]
  @any {__MODULE__, :any_target}
  @snapshot {__MODULE__, :snapshot}
  @env {__MODULE__, :env}

  @doc "Runs a phase. Returns the env, also when a thrown failure leaves the phase early: see `last_env/0`."
  def run(statements, env, ctx) do
    Enum.reduce(statements, env, fn statement, env ->
      env = exec(statement, env, ctx)
      Process.put(@env, env)
      env
    end)
  end

  @doc "The env after the last finished top-level statement, so Cleanup sees what Setup declared (C116)."
  def last_env, do: Process.get(@env)

  @doc "Forgets the target `sut.any` picked: the next iteration picks a new one (C168)."
  def new_iteration, do: Process.delete(@any)

  @doc "A stopIf condition. A condition with no value yet is false."
  def condition(node, ctx) do
    eval(node, [], ctx) == true
  catch
    {:perflang, :stop_phase} -> false
  end

  @doc "The value of a user curve at `args`, the time first (C28, C30)."
  def curve(%AST.CurveDefinition{params: params, body: body}, args, ctx) do
    eval(body, [params |> Enum.zip(args) |> Map.new()], ctx)
  end

  # ---------- Statements ----------

  defp exec(%AST.Let{} = node, env, ctx) do
    value = node.value |> eval(env, ctx) |> coerce(node.type, node, ctx)
    track(node.name, value, env, ctx)

    value =
      if node.mutable and is_list(value) do
        Cells.new(value, if(ctx.phase == :setup, do: ctx.test.cells))
      else
        value
      end

    put(env, node.name, value)
  end

  defp exec(%AST.Assign{name: name} = node, env, ctx) do
    value = eval(node.value, env, ctx)
    track(name, value, env, ctx)

    case lookup(env, name) do
      {:ok, {:cell, _table, _id} = cell} when is_list(value) ->
        Cells.write(cell, value)
        env

      _ ->
        assign(env, name, value)
    end
  end

  defp exec(%AST.Assert{condition: condition} = node, env, ctx) do
    passed? =
      try do
        condition |> eval(env, ctx) |> truth(condition, ctx)
      catch
        {:perflang, :stop_phase} = stop ->
          if ctx.phase == :verify, do: report(:assert, condition, false, env, ctx)
          throw(stop)
      end

    if ctx.phase == :verify, do: report(:assert, condition, passed?, env, ctx)

    if passed? do
      Recorder.assert_passed(ctx.test.recorder, ctx.phase, warmup?(ctx))
      env
    else
      failed_assert(node, ctx)
      leave(ctx)
      env
    end
  end

  defp exec(%AST.Check{condition: condition} = node, env, ctx) do
    passed? = condition |> eval(env, ctx) |> truth(condition, ctx)
    if ctx.phase == :verify, do: report(:check, condition, passed?, env, ctx)

    if passed?,
      do: Recorder.check_passed(ctx.test.recorder, warmup?(ctx)),
      else: Recorder.check_failed(ctx.test.recorder, ctx.phase, node, warmup?(ctx))

    env
  end

  defp exec(%AST.If{condition: condition} = node, env, ctx) do
    cond do
      condition |> eval(env, ctx) |> truth(condition, ctx) -> block(node.then, env, ctx)
      node.else -> exec(node.else, env, ctx)
      true -> env
    end
  end

  defp exec(%AST.Block{} = node, env, ctx), do: block(node, env, ctx)

  defp exec(%AST.While{condition: condition} = node, env, ctx) do
    if ctx.phase == :actions, do: Http.check_stop()

    if condition |> eval(env, ctx) |> truth(condition, ctx),
      do: exec(node, block(node.body, env, ctx), ctx),
      else: env
  end

  defp exec(%AST.For{var: var, body: body} = node, env, ctx) do
    items = items(eval(node.iterable, env, ctx), node, ctx)

    Enum.reduce(items, env, fn item, env ->
      if ctx.phase == :actions, do: Http.check_stop()
      tl(statements(body.statements, [%{var => item} | env], ctx))
    end)
  end

  defp exec(%AST.Return{value: nil}, _env, _ctx), do: throw({:perflang, :return, :unit})
  defp exec(%AST.Return{value: value}, env, ctx), do: throw({:perflang, :return, eval(value, env, ctx)})

  defp exec(%AST.ExpressionStatement{expression: expression}, env, ctx) do
    eval(expression, env, ctx)
    env
  end

  defp exec(%AST.MatchStatement{match: match}, env, ctx) do
    {_value, env} = match(match, env, ctx)
    env
  end

  defp statements(statements, env, ctx), do: Enum.reduce(statements, env, &exec(&1, &2, ctx))
  defp block(%AST.Block{statements: statements}, env, ctx), do: tl(statements(statements, [%{} | env], ctx))

  # ---------- Failures (C116, C125, C141) ----------

  defp warmup?(%{phase: :actions, test: test}), do: Recorder.warmup?(test.recorder)
  defp warmup?(_ctx), do: false

  defp failed_assert(node, ctx), do: Recorder.assert_failed(ctx.test.recorder, ctx.phase, node, warmup?(ctx))

  defp leave(%{phase: :actions}), do: throw({:perflang, :end_iteration})
  defp leave(%{phase: :setup}), do: throw({:perflang, :stop_phase})
  defp leave(_ctx), do: :ok

  # A failed assert with no value to go on with: every phase stops here (C141).
  defp no_value(_node, %{phase: :stop_if}), do: throw({:perflang, :stop_phase})
  defp no_value(_node, %{quiet: true}), do: throw({:perflang, :stop_phase})

  defp no_value(node, ctx) do
    failed_assert(node, ctx)
    if ctx.phase == :actions, do: throw({:perflang, :end_iteration}), else: throw({:perflang, :stop_phase})
  end

  defp truth(value, _node, _ctx) when is_boolean(value), do: value
  defp truth(_value, node, ctx), do: no_value(node, ctx)

  defp report(kind, condition, passed?, env, ctx) do
    values =
      for node <- Source.measured(condition) do
        value =
          try do
            eval(node, env, Map.put(ctx, :quiet, true))
          catch
            {:perflang, :stop_phase} -> nil
          end

        {Source.text(node), value}
      end

    Recorder.verify_result(ctx.test.recorder, %{
      kind: kind,
      source: Source.text(condition),
      line: elem(condition_loc(condition), 0),
      column: elem(condition_loc(condition), 1),
      values: values,
      passed: passed?
    })
  end

  defp condition_loc(%AST.Binary{left: left}), do: condition_loc(left)
  defp condition_loc(%AST.Member{object: object}), do: condition_loc(object)
  defp condition_loc(%AST.Call{callee: callee}), do: condition_loc(callee)
  defp condition_loc(%AST.Index{object: object}), do: condition_loc(object)
  defp condition_loc(%{loc: loc}), do: loc

  defp coerce(value, nil, _node, _ctx), do: value
  defp coerce(value, %AST.Type{name: "Int"}, _node, _ctx) when is_integer(value), do: value
  defp coerce(value, %AST.Type{name: "Float"}, _node, _ctx) when is_number(value), do: value / 1
  defp coerce(value, %AST.Type{name: "Bool"}, _node, _ctx) when is_boolean(value), do: value
  defp coerce(value, %AST.Type{name: "String"}, _node, _ctx) when is_binary(value), do: value
  defp coerce(value, %AST.Type{name: "List"}, _node, _ctx) when is_list(value), do: value

  defp coerce(_value, %AST.Type{name: name}, node, ctx)
       when name in ["Int", "Float", "Bool", "String", "List"],
       do: no_value(node, ctx)

  defp coerce(value, _type, _node, _ctx), do: value

  # ---------- Scopes ----------

  defp put([scope | rest], name, value), do: [Map.put(scope, name, value) | rest]

  defp assign([], _name, _value), do: []

  defp assign([scope | rest], name, value) do
    if is_map_key(scope, name),
      do: [Map.put(scope, name, value) | rest],
      else: [scope | assign(rest, name, value)]
  end

  defp lookup([], _name), do: :error

  defp lookup([scope | rest], name) do
    case scope do
      %{^name => value} -> {:ok, value}
      _ -> lookup(rest, name)
    end
  end

  # An Actions variable that Verify or Cleanup reads (C136), with when it was set,
  # so the last one wins when workers send theirs.
  defp track(name, value, env, %{phase: :actions, test: test}) do
    if length(env) == 2 and MapSet.member?(test.tracked, name) do
      :ets.insert(test.vars, {name, value, Recorder.now()})
    end
  end

  defp track(_name, _value, _env, _ctx), do: :ok

  # ---------- Expressions ----------

  defp eval(%AST.Var{name: name} = node, env, ctx) do
    case lookup(env, name) do
      {:ok, :unset} ->
        no_value(node, ctx)

      {:ok, {:cell, _table, _id} = cell} ->
        Cells.read(cell)

      {:ok, value} ->
        value

      :error ->
        cond do
          name == "pi" -> :math.pi()
          name == "e" -> :math.exp(1)
          is_map_key(ctx.rt.fns, name) -> {:fn_ref, name}
          name in ~w(sin cos exp log sqrt abs linear) -> {:builtin, name}
          true -> no_value(node, ctx)
        end
    end
  end

  defp eval(%AST.Member{object: %AST.Var{name: "sut"}, name: name} = node, env, ctx) do
    case lookup(env, "sut") do
      :error when name == "any" -> any_target(node, ctx)
      :error -> {:target, name}
      {:ok, _value} -> no_value(node, ctx)
    end
  end

  defp eval(%AST.Member{object: object, name: name} = node, env, ctx) do
    case eval(object, env, ctx) do
      %{status: _status} = response -> Map.fetch!(response, String.to_existing_atom(name))
      _ -> no_value(node, ctx)
    end
  end

  defp eval(%AST.Index{object: object, index: index} = node, env, ctx) do
    case {eval(object, env, ctx), eval(index, env, ctx)} do
      {list, position}
      when is_list(list) and is_integer(position) and position >= 0 and position < length(list) ->
        Enum.at(list, position)

      {map, key} when is_map(map) and is_binary(key) and is_map_key(map, key) ->
        map[key]

      _ ->
        no_value(node, ctx)
    end
  end

  defp eval(%AST.Binary{op: :&&, left: left, right: right}, env, ctx) do
    left_value = left |> eval(env, ctx) |> truth(left, ctx)
    left_value and right |> eval(env, ctx) |> truth(right, ctx)
  end

  defp eval(%AST.Binary{op: :||, left: left, right: right}, env, ctx) do
    left_value = left |> eval(env, ctx) |> truth(left, ctx)
    left_value or right |> eval(env, ctx) |> truth(right, ctx)
  end

  defp eval(%AST.Binary{op: :==, left: left, right: right}, env, ctx),
    do: Values.equal?(eval(left, env, ctx), eval(right, env, ctx))

  defp eval(%AST.Binary{op: :!=, left: left, right: right}, env, ctx),
    do: not Values.equal?(eval(left, env, ctx), eval(right, env, ctx))

  defp eval(%AST.Binary{op: op, left: left, right: right} = node, env, ctx) when op in [:<, :<=, :>, :>=] do
    case Values.compare(op, eval(left, env, ctx), eval(right, env, ctx)) do
      {:ok, value} -> value
      :error -> no_value(node, ctx)
    end
  end

  defp eval(%AST.Binary{op: op, left: left, right: right} = node, env, ctx) do
    case Values.arithmetic(op, eval(left, env, ctx), eval(right, env, ctx)) do
      {:ok, value} -> value
      :error -> no_value(node, ctx)
    end
  end

  defp eval(%AST.Unary{op: :!, operand: operand}, env, ctx),
    do: not (operand |> eval(env, ctx) |> truth(operand, ctx))

  defp eval(%AST.Unary{operand: operand} = node, env, ctx) do
    case Values.negate(eval(operand, env, ctx)) do
      {:ok, value} -> value
      :error -> no_value(node, ctx)
    end
  end

  defp eval(%AST.Lambda{params: params, body: body}, env, _ctx),
    do: {:closure, Enum.map(params, & &1.name), body, env}

  defp eval(%AST.ListOperation{} = node, env, ctx), do: list_operation(node, env, ctx)
  defp eval(%AST.Metric{target: nil} = node, _env, ctx), do: metric(node, ctx)

  # A request metric per target (C176). A target that got no counted request
  # has no value, so a criterion on it fails.
  defp eval(%AST.Metric{target: target} = node, env, ctx) do
    with {:target, name} <- eval(target, env, ctx),
         %{requests: requests} = stats when requests > 0 <- snapshot(ctx).targets[name] do
      request_metric(node, stats, ctx)
    else
      _ -> no_value(node, ctx)
    end
  end

  defp eval(%AST.Match{} = node, env, ctx) do
    {value, _env} = match(node, env, ctx)
    value
  end

  defp eval(%AST.JsonObject{members: members}, env, ctx),
    do: Map.new(members, &{&1.key, eval(&1.value, env, ctx)})

  defp eval(%AST.JsonArray{items: items}, env, ctx), do: Enum.map(items, &eval(&1, env, ctx))
  defp eval(%AST.Null{}, _env, _ctx), do: nil
  defp eval(%AST.Call{} = node, env, ctx), do: call(node, env, ctx)
  defp eval(literal, _env, _ctx), do: Values.literal(literal)

  # sut.any picks once per iteration, by the distribution of the Load (C168).
  defp any_target(node, %{phase: :actions} = ctx) do
    case Process.get(@any) do
      nil ->
        target = pick(ctx.test.load.distribution, :rand.uniform(10_000))
        Process.put(@any, target)
        target

      target ->
        target
    end
    |> case do
      nil -> no_value(node, ctx)
      target -> target
    end
  end

  defp any_target(node, ctx), do: no_value(node, ctx)

  defp pick([], _roll), do: nil
  defp pick([{name, share} | _rest], roll) when roll <= share, do: {:target, name}
  defp pick([{_name, share} | rest], roll), do: pick(rest, roll - share)

  # ---------- Match (C75) ----------

  defp match(%AST.Match{subject: subject, arms: arms}, env, ctx) do
    value = eval(subject, env, ctx)
    Enum.find_value(arms, {:unit, env}, &arm(&1, value, env, ctx))
  end

  defp arm(%AST.MatchArm{pattern: pattern, guard: guard, body: body}, value, env, ctx) do
    case bind(pattern, value, ctx) do
      :no_match ->
        nil

      {:ok, bindings} ->
        scope = [bindings | env]

        if guard == nil or guard |> eval(scope, ctx) |> truth(guard, ctx) do
          case body do
            %AST.Block{} -> {:unit, tl(block(body, scope, ctx))}
            _ -> {eval(body, scope, ctx), env}
          end
        end
    end
  end

  defp bind(%AST.WildcardPattern{}, _value, _ctx), do: {:ok, %{}}
  defp bind(%AST.BindPattern{name: name}, value, _ctx), do: {:ok, %{name => value}}

  defp bind(%AST.LiteralPattern{literal: literal, negative: negative}, value, _ctx) do
    expected = Values.literal(literal)
    expected = if negative, do: elem(Values.negate(expected), 1), else: expected
    if Values.equal?(expected, value), do: {:ok, %{}}, else: :no_match
  end

  # ---------- Lists (C91, C134, C145) ----------

  defp items(list, _node, _ctx) when is_list(list), do: list
  defp items(_value, node, ctx), do: no_value(node, ctx)

  defp list_operation(%AST.ListOperation{op: op, function: function} = node, env, ctx) do
    list = items(eval(node.receiver, env, ctx), node, ctx)
    fun = eval(function, env, ctx)

    case op do
      :map ->
        Enum.map(list, &apply_value(fun, [&1], node, ctx))

      :filter ->
        Enum.filter(list, &(fun |> apply_value([&1], node, ctx) |> truth(node, ctx)))

      :foldr ->
        init = eval(node.init, env, ctx)
        List.foldr(list, init, &apply_value(fun, [&1, &2], node, ctx))

      _fold ->
        init = eval(node.init, env, ctx)
        List.foldl(list, init, &apply_value(fun, [&2, &1], node, ctx))
    end
  end

  # ---------- Calls ----------

  defp call(%AST.Call{callee: %AST.Var{name: name}, args: args} = node, env, ctx) do
    case lookup(env, name) do
      {:ok, _value} ->
        apply_value(eval(node.callee, env, ctx), Enum.map(args, &eval(&1, env, ctx)), node, ctx)

      :error ->
        values = Enum.map(args, &eval(&1, env, ctx))

        cond do
          ctx.phase == :curve and is_map_key(ctx.test.load.curves, name) ->
            curve(ctx.test.load.curves[name], values, ctx)

          is_map_key(ctx.rt.fns, name) ->
            call_fn(ctx.rt.fns[name], values, node, ctx)

          true ->
            builtin(name, values, node, ctx)
        end
    end
  end

  defp call(%AST.Call{callee: %AST.Member{object: %AST.Http{}, name: method}} = node, env, ctx),
    do: http(nil, method, node, env, ctx)

  defp call(
         %AST.Call{callee: %AST.Member{object: %AST.Member{name: "http", object: object}, name: method}} =
           node,
         env,
         ctx
       ) do
    case eval(object, env, ctx) do
      {:target, name} -> http(name, method, node, env, ctx)
      _ -> no_value(node, ctx)
    end
  end

  defp call(
         %AST.Call{callee: %AST.Member{object: %AST.Member{name: metric} = reading, name: stat}} = node,
         env,
         ctx
       )
       when metric in @machine_metrics do
    source =
      case reading.object do
        %AST.Var{name: "sut"} -> :all
        %AST.Var{name: "loadGenerator"} -> :load_generator
        %AST.Member{object: %AST.Var{name: "loadGenerator"}, name: worker} -> {:load_generator, worker}
        object -> eval(object, env, ctx)
      end

    case Monitor.reading(ctx.test.monitor, source, metric, stat) do
      {:ok, value} -> value
      :error -> no_value(node, ctx)
    end
  end

  defp call(
         %AST.Call{callee: %AST.Member{object: %AST.Var{} = object, name: "add"}, args: [arg]} = node,
         env,
         ctx
       ) do
    value = eval(arg, env, ctx)

    case lookup(env, object.name) do
      {:ok, {:cell, _table, _id} = cell} ->
        Cells.add(cell, value)
        :unit

      _ ->
        no_value(node, ctx)
    end
  end

  # The static type decides between Int and Float, since an Int widened to a Float can still
  # be a whole number here, e.g. min(1, 2.5) or a Float variable assigned an Int (C139, C177).
  defp call(%AST.Call{callee: %AST.Member{object: object, name: "toString"}, args: []} = node, env, ctx) do
    value = eval(object, env, ctx)
    value = if object.type == :float and is_number(value), do: value / 1, else: value

    case Values.to_text(value) do
      {:ok, text} -> text
      :error -> no_value(node, ctx)
    end
  end

  defp call(%AST.Call{callee: %AST.Member{object: object, name: name}, args: args} = node, env, ctx) do
    method(name, eval(object, env, ctx), Enum.map(args, &eval(&1, env, ctx)), node, ctx)
  end

  defp call(%AST.Call{callee: callee, args: args} = node, env, ctx),
    do: apply_value(eval(callee, env, ctx), Enum.map(args, &eval(&1, env, ctx)), node, ctx)

  defp apply_value({:closure, params, body, env}, args, _node, ctx),
    do: eval(body, [params |> Enum.zip(args) |> Map.new() | env], ctx)

  defp apply_value({:fn_ref, name}, args, node, ctx), do: call_fn(ctx.rt.fns[name], args, node, ctx)
  defp apply_value({:builtin, name}, args, node, ctx), do: builtin(name, args, node, ctx)
  defp apply_value(_value, _args, node, ctx), do: no_value(node, ctx)

  defp call_fn(%AST.FnDeclaration{params: params, body: body, return_type: return}, args, node, ctx) do
    scope =
      params
      |> Enum.zip(args)
      |> Map.new(fn {param, value} -> {param.name, coerce(value, param.type, node, ctx)} end)

    try do
      statements(body.statements, [scope], ctx)
      :unit
    catch
      {:perflang, :return, value} -> coerce(value, return, node, ctx)
    end
  end

  defp method("length", list, [], _node, _ctx) when is_list(list), do: length(list)

  defp method("contains", list, [value], _node, _ctx) when is_list(list),
    do: Enum.any?(list, &Values.equal?(&1, value))

  # A JSON value that is not an array counts as an empty list (C134).
  defp method("random", [_ | _] = list, [], _node, _ctx), do: Enum.random(list)

  defp method("random", list, [count], _node, _ctx)
       when is_list(list) and count >= 0 and count <= length(list),
       do: Enum.take_random(list, count)

  defp method(_name, _value, _args, node, ctx), do: no_value(node, ctx)

  defp builtin("sin", [x], _node, _ctx) when is_number(x), do: :math.sin(x)
  defp builtin("cos", [x], _node, _ctx) when is_number(x), do: :math.cos(x)
  defp builtin("abs", [x], _node, _ctx) when is_number(x), do: abs(x) / 1
  defp builtin("linear", [x], _node, _ctx) when is_number(x), do: x / 1
  defp builtin("sqrt", [x], _node, _ctx) when is_number(x) and x >= 0, do: :math.sqrt(x)
  defp builtin("log", [x], _node, _ctx) when is_number(x) and x > 0, do: :math.log(x)

  defp builtin("exp", [x], node, ctx) when is_number(x) do
    :math.exp(x)
  rescue
    ArithmeticError -> no_value(node, ctx)
  end

  defp builtin(name, [left, right], node, ctx) when name in ["min", "max"] do
    case Values.limit(String.to_existing_atom(name), left, right) do
      {:ok, value} -> value
      :error -> no_value(node, ctx)
    end
  end

  defp builtin("range", [from, to], _node, _ctx) when is_integer(from) and is_integer(to),
    do: if(from < to, do: Enum.to_list(from..(to - 1)), else: [])

  defp builtin("sleep", [{:time, ms}], _node, ctx) when ms >= 0 do
    if Http.sleep(ms) == :stopped and ctx.phase == :actions, do: Http.check_stop()
    :unit
  end

  defp builtin(_name, _args, node, ctx), do: no_value(node, ctx)

  # ---------- http (C112-C115, C123) ----------

  @body_methods ~w(post put patch)

  defp http(target, method, %AST.Call{args: [url | rest]} = node, env, ctx) do
    {body_node, options_node} =
      case {method in @body_methods, rest} do
        {true, [body, options]} -> {body, options}
        {true, [body]} -> {body, nil}
        {false, [options]} -> {nil, options}
        _ -> {nil, nil}
      end

    url = eval(url, env, ctx)
    options = if options_node, do: eval(options_node, env, ctx), else: %{}
    unless is_binary(url) and is_map(options), do: no_value(node, ctx)
    {payload, content_type} = body(body_node, env, ctx)

    request(target, String.upcase(method), url, payload, content_type, options, ctx)
    |> Http.call(ctx)
  end

  defp body(nil, _env, _ctx), do: {nil, nil}

  defp body(node, env, ctx) do
    case {node.type, eval(node, env, ctx)} do
      {:string, ""} -> {nil, nil}
      {:string, text} -> {text, "text/plain; charset=utf-8"}
      {_type, value} -> {JSON.encode!(value), "application/json"}
    end
  end

  defp request(target, method, url, payload, content_type, options, ctx) do
    query = options |> Map.get("query", %{}) |> Enum.map(fn {key, value} -> {key, plain(value)} end)
    base = if target, do: base_url(target, ctx)
    sent = if query == [], do: url, else: "#{url}?#{URI.encode_query(query)}"
    full = if target, do: base && base <> sent, else: sent
    parsed = if full, do: URI.parse(full)

    %{
      target: target,
      method: method,
      url: sent,
      path: url,
      full_url: full,
      target_path: parsed && path_of(parsed),
      headers: headers(Map.get(options, "headers", %{}), content_type),
      body: payload
    }
  end

  defp base_url(target, ctx) do
    case ctx.rt.targets[target] do
      %{base_url: base} -> base
      _ -> nil
    end
  end

  defp path_of(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query, do: "#{path}?#{query}", else: path
  end

  # A Content-Type in the options replaces the default (C123).
  defp headers(given, content_type) do
    given = Enum.map(given, fn {name, value} -> {String.downcase(name), plain(value)} end)

    if content_type && not List.keymember?(given, "content-type", 0),
      do: [{"content-type", content_type} | given],
      else: given
  end

  defp plain(value) when is_binary(value), do: value
  defp plain(value), do: to_string(value)

  # ---------- Metrics (C60, C107, C118, C130, C161, C172) ----------

  defp snapshot(%{phase: phase, test: test}) when phase in [:verify, :cleanup] do
    case Process.get(@snapshot) do
      nil ->
        snapshot = Recorder.snapshot(test.recorder)
        Process.put(@snapshot, snapshot)
        snapshot

      snapshot ->
        snapshot
    end
  end

  defp snapshot(%{test: test}), do: Recorder.snapshot(test.recorder)

  # stopIf reads the live counters, and needs a scan only for latency (C58).
  defp totals(%{phase: :stop_if, test: test}), do: Recorder.live(test.recorder)
  defp totals(ctx), do: snapshot(ctx).totals

  defp sorted_latencies(%{phase: :stop_if, test: test}), do: Recorder.live_latencies(test.recorder)
  defp sorted_latencies(ctx), do: snapshot(ctx).totals.latencies

  defp metric(%AST.Metric{group: :latency} = node, ctx), do: latency(node, sorted_latencies(ctx), ctx)

  defp metric(%AST.Metric{group: group} = node, ctx) when group in [:throughput, :errors],
    do: request_metric(node, totals(ctx), ctx)

  defp metric(%AST.Metric{group: group, measurement: :rate}, ctx) when group in [:asserts, :checks],
    do: {:percentage, Recorder.rate(ctx.test.recorder, group)}

  defp metric(%AST.Metric{group: group}, ctx) when group in [:asserts, :checks],
    do: Recorder.failed(ctx.test.recorder, group)

  defp metric(%AST.Metric{group: group, measurement: measurement} = node, ctx) do
    requests = totals(ctx).requests

    case Monitor.energy_metric(ctx.test.monitor, group, measurement, requests) do
      {:ok, value} -> value
      :error -> no_value(node, ctx)
    end
  end

  # The totals, or the stats of one target: the same rules for both (C135, C176).
  defp request_metric(%AST.Metric{group: :latency} = node, stats, ctx),
    do: latency(node, stats.latencies, ctx)

  defp request_metric(%AST.Metric{group: :throughput}, stats, _ctx), do: stats.throughput / 1

  defp request_metric(%AST.Metric{group: :errors, measurement: :rate}, stats, _ctx),
    do: {:percentage, stats.errors.rate}

  defp request_metric(%AST.Metric{group: :errors, measurement: measurement}, stats, _ctx),
    do: Map.fetch!(stats.errors, measurement)

  defp latency(%AST.Metric{measurement: :percentile, argument: argument} = node, sorted, ctx) do
    case Recorder.percentile(sorted, argument.value) do
      nil -> no_value(node, ctx)
      value -> {:time, value}
    end
  end

  defp latency(%AST.Metric{measurement: measurement} = node, sorted, ctx) do
    case Recorder.latency_stats(sorted) do
      nil -> no_value(node, ctx)
      latency -> {:time, Map.fetch!(latency, measurement)}
    end
  end
end
