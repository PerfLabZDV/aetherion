defmodule Aetherion do
  @moduledoc """
  Runs a suite that the Analyzer has accepted.

      {:ok, ast} = PerfLang.analyze(ast, config: config)
      %{exit_code: 0} = Aetherion.run(ast, seed: 42)

  Tests run in order, one at a time (C166). Each runs Setup, then Actions under
  its Load, then Verify; Cleanup runs once the Test has started, whatever
  happened before it (C155). A phase runs in its own process, so a phase over its
  limit can be stopped (C171).

  With a runs section (C178) the whole suite runs several times, each run with
  its own seed (C179), and every Test gets statistics across the counted runs
  (C180). `run.runs` holds each run with its Tests, `run.tests` each Test across
  the runs.

  Exit codes follow C132: 0 when every Test passed in every counted run, 1 when
  a Test failed, 2 when the run could not finish.
  """

  alias PerfLang.AST
  alias Aetherion.{Http, Interpreter, Load, Monitor, Recorder, Report, Signals, Stats, Values}

  @phase_limit :timer.minutes(5)

  @doc """
  Options: `:seed`, `:runs` (replaces the count of the runs section), `:report` (false for no
  console report), `:phase_limit_ms`, `:signals` (false to leave them alone).
  """
  def run(%AST.TestSuite{} = ast, opts \\ []) do
    plan =
      case plan(ast, opts[:runs]) do
        {:ok, plan} -> plan
        {:error, message} -> raise ArgumentError, message
      end

    seed = opts[:seed] || :rand.uniform(2_147_483_647)
    started_at = DateTime.utc_now()
    started = Recorder.now()
    if Keyword.get(opts, :signals, true), do: Signals.install(self())
    rt = runtime(ast, seed, opts)

    {runs, status, message} =
      try do
        out = Report.open(rt.output)
        {runs, status} = run_all(ast, rt, out, plan)
        last = List.last(runs)
        {runs, status, (last && last.message) || status_message(status)}
      rescue
        error in File.Error -> {[], :failed, Exception.message(error)}
      end

    run = %{
      suite: ast.name,
      seed: seed,
      plan: plan,
      started_at: started_at,
      duration_ms: round(Recorder.now() - started),
      runs: runs,
      tests: experiment_tests(ast, runs),
      status: status,
      message: message
    }

    if Keyword.get(opts, :report, true), do: Report.console(run)
    write_summary(rt, run)
    Map.put(run, :exit_code, exit_code(run))
  end

  @doc """
  The runs of a suite (C178): count, discard and cooldown, with `runs` from the command line in
  place of count. `{:error, message}` when no run would count.
  """
  def plan(%AST.TestSuite{config: config}, runs \\ nil) do
    sections = if config, do: config.sections, else: []
    settings = for %AST.Runs{settings: settings} <- sections, setting <- settings, do: setting
    count = runs || setting(settings, AST.RunsCount) || 1
    discard = setting(settings, AST.RunsDiscard) || 0
    plan = %{count: count, discard: discard, cooldown_ms: time(setting(settings, AST.RunsCooldown), 0)}

    cond do
      count < 1 ->
        {:error, "runs must be at least 1, got #{count} (C178)"}

      discard >= count ->
        {:error,
         "#{count} runs with discard #{discard} leave no counted run; run more than #{discard} (C178)"}

      true ->
        {:ok, plan}
    end
  end

  @doc "The seed of a run (C179): the seed itself for run 1, so one run replays alone with its own seed."
  def run_seed(seed, 1), do: seed
  def run_seed(seed, run), do: :erlang.phash2({seed, run}, 2_147_483_646) + 1

  defp write_summary(%{output: %{summary: nil}}, _run), do: :ok

  defp write_summary(%{output: %{summary: file}}, run),
    do: Report.write_summary(Report.path(file), Report.summary(run))

  defp status_message(:ok), do: nil
  defp status_message(:interrupted), do: "The run was interrupted."
  defp status_message(:limit), do: "A Setup or Cleanup went over its time limit."
  defp status_message(:crashed), do: "The run could not finish."

  defp exit_code(%{status: :ok, tests: tests}) do
    if Enum.any?(tests, &(&1.result == :failed)), do: 1, else: 0
  end

  defp exit_code(_run), do: 2

  # ---------- Runs (C178-C180) ----------

  # The whole suite, once per run, in order. A run that does not finish ends the
  # experiment, and so does an interrupt during the cooldown (C178).
  defp run_all(ast, rt, out, plan) do
    {runs, status} =
      Enum.reduce_while(1..plan.count, {[], :ok}, fn index, {runs, _status} ->
        run = run_once(ast, rt, out, plan, index)
        runs = [run | runs]

        cond do
          run.status != :ok -> {:halt, {runs, run.status}}
          index == plan.count -> {:cont, {runs, :ok}}
          cooldown(plan.cooldown_ms) == :ok -> {:cont, {runs, :ok}}
          true -> {:halt, {runs, :interrupted}}
        end
      end)

    {Enum.reverse(runs), status}
  end

  defp run_once(ast, rt, out, plan, index) do
    seed = run_seed(rt.seed, index)
    rt = %{rt | seed: seed, run: index}
    started_at = DateTime.utc_now()
    started = Recorder.now()

    {tests, status, message} =
      try do
        {tests, status} = run_tests(ast.tests, ast.load, rt, out)
        {tests, status, status_message(status)}
      rescue
        error in [Monitor.Error, File.Error] -> {[], :failed, Exception.message(error)}
      end

    %{
      run: index,
      seed: seed,
      discarded: index <= plan.discard,
      started_at: started_at,
      duration_ms: round(Recorder.now() - started),
      tests: tests,
      status: status,
      message: message
    }
  end

  # Nothing is sampled during the cooldown; an interrupt ends it at once.
  defp cooldown(ms) when ms <= 0, do: :ok

  defp cooldown(ms) do
    receive do
      :perflang_interrupt -> :interrupted
    after
      round(ms) -> :ok
    end
  end

  # Each Test across the counted runs: finished and not discarded (C178). It
  # passes when it passed in every one of them, and the statistics describe
  # its metrics over them (C180).
  defp experiment_tests(ast, runs) do
    counted = Enum.filter(runs, &(&1.status == :ok and not &1.discarded))

    for test <- ast.tests do
      results = for run <- counted, result <- run.tests, result.name == test.name, do: result
      failed = Enum.count(results, &(&1.result == :failed))

      %{
        name: test.name,
        result:
          cond do
            results == [] -> :aborted
            failed > 0 -> :failed
            true -> :passed
          end,
        counted: length(results),
        passed: Enum.count(results, &(&1.result == :passed)),
        failed: failed,
        aggregate: Stats.aggregate(Enum.map(results, &Report.test_summary/1))
      }
    end
  end

  defp run_tests(tests, suite_load, rt, out) do
    {results, status} =
      tests
      |> Enum.with_index(1)
      |> Enum.reduce_while({[], :ok}, fn {test, index}, {results, _status} ->
        {result, status} = run_test(test, index, test.load || suite_load, rt, out)

        if status == :ok,
          do: {:cont, {[result | results], :ok}},
          else: {:halt, {[result | results], status}}
      end)

    {Enum.reverse(results), status}
  end

  # ---------- One Test ----------

  defp run_test(test, index, load, rt, out) do
    recorder = Recorder.new()
    monitor = Monitor.start(rt, recorder)
    cells = :ets.new(:cells, [:ordered_set, :public])
    vars = :ets.new(:vars, [:set, :public])

    context = %{
      name: test.name,
      index: index,
      recorder: recorder,
      monitor: monitor,
      load: load_config(load),
      cells: cells,
      vars: vars,
      tracked: tracked(test),
      actions: test.actions.statements,
      setup_scope: %{}
    }

    ctx = %{rt: rt, test: context, phase: :setup, vu: nil, iteration: nil}

    {stopped_by, status} =
      try do
        {setup, env} = phase(test.setup, [%{}], ctx)
        setup_scope = hd(env)
        ctx = put_in(ctx.test.setup_scope, setup_scope)

        {stopped_by, status} =
          if setup == :ok do
            load_and_verify(test, %{ctx | phase: :actions}, setup_scope)
          else
            {nil, setup}
          end

        {cleanup, _env} = phase(test.cleanup, late_env(ctx, setup_scope), %{ctx | phase: :cleanup})
        {stopped_by, worse(status, cleanup)}
      after
        Recorder.flush()
      end

    Monitor.stop(monitor)
    status = run_status(status)
    result = finish_test(test, ctx, stopped_by, out)

    # Verify did not decide, so the Test has no result of its own.
    {if(status == :ok, do: result, else: %{result | result: :aborted}), status}
  end

  defp run_status(status) when status in [:ok, :stopped], do: :ok
  defp run_status(status), do: status

  defp worse(status, :ok), do: status
  defp worse(status, :stopped), do: status
  defp worse(status, _cleanup) when status in [:interrupted, :crashed], do: status
  defp worse(_status, cleanup), do: cleanup

  defp load_and_verify(test, ctx, setup_scope) do
    Monitor.set_phase(ctx.test.monitor, :actions)
    Recorder.start_window(ctx.test.recorder, ctx.test.load.warmup_ms)

    outcome =
      try do
        Load.run(ctx)
      rescue
        error ->
          IO.puts(:stderr, "error: #{Exception.message(error)}")
          :crashed
      end

    Recorder.end_window(ctx.test.recorder)

    case outcome do
      :interrupted ->
        {nil, :interrupted}

      :crashed ->
        {nil, :crashed}

      other ->
        {verify, _env} = phase(test.verify, late_env(ctx, setup_scope), %{ctx | phase: :verify})
        {stopped_by(other), verify}
    end
  end

  defp stopped_by({:stopped, source}), do: source
  defp stopped_by(_finished), do: nil

  # Verify and Cleanup see Setup, and the Actions variables they read (C136).
  defp late_env(ctx, setup_scope) do
    actions =
      Map.new(ctx.test.tracked, fn name ->
        case :ets.lookup(ctx.test.vars, name) do
          [{^name, value}] -> {name, value}
          [] -> {name, :unset}
        end
      end)

    [%{}, actions, setup_scope]
  end

  defp finish_test(test, ctx, stopped_by, out) do
    %{recorder: recorder, monitor: monitor} = ctx.test
    requests = Recorder.snapshot(recorder).totals.requests

    energy =
      for {group, measurements} <- [
            energy: ~w(total perRequest perUser)a,
            power: ~w(mean peak)a,
            carbon: ~w(total perRequest)a
          ],
          value = energy_group(monitor, group, measurements, requests),
          into: %{},
          do: {group, value}

    result = %{
      name: test.name,
      result: Recorder.result(recorder),
      stopped_by: stopped_by,
      snapshot: Recorder.snapshot(recorder),
      asserts: %{failed: Recorder.failed(recorder, :asserts), rate: Recorder.rate(recorder, :asserts)},
      checks: %{failed: Recorder.failed(recorder, :checks), rate: Recorder.rate(recorder, :checks)},
      energy: energy,
      targets: Monitor.report(monitor),
      # The targets that take requests, so one that got none still shows (C176).
      request_targets: Enum.sort(for({name, %{base_url: url}} <- ctx.rt.targets, url != nil, do: name)),
      load_generator: Monitor.load_generator(monitor),
      verify: Recorder.verify_results(recorder),
      failures: Recorder.failures(recorder)
    }

    Report.write_requests(out.requests, Recorder.records(recorder), ctx.rt.run)
    Report.write_samples(out.samples, Monitor.all_samples(monitor), ctx.rt.run)
    Recorder.delete(recorder)
    Monitor.delete(monitor)
    :ets.delete(ctx.test.cells)
    :ets.delete(ctx.test.vars)
    result
  end

  defp energy_group(monitor, group, measurements, requests) do
    pairs =
      for measurement <- measurements,
          {:ok, value} <- [Monitor.energy_metric(monitor, group, measurement, requests)],
          do: {measurement, Values.plain(value)}

    if pairs != [], do: Map.new(pairs)
  end

  # ---------- Phases (C116, C155, C171) ----------

  defp phase(nil, env, _ctx), do: {:ok, env}

  defp phase(%AST.Phase{statements: statements}, env, ctx) do
    Monitor.set_phase(ctx.test.monitor, ctx.phase)
    parent = self()
    ref = make_ref()

    {pid, down} =
      spawn_monitor(fn ->
        :rand.seed(:exsss, {ctx.rt.seed, ctx.test.index, 0})

        status =
          try do
            Interpreter.run(statements, env, ctx)
            :ok
          catch
            {:perflang, :stop_phase} -> :stopped
          end

        Recorder.flush()
        Http.close()
        send(parent, {ref, status, Interpreter.last_env() || env})
      end)

    await_phase(pid, ref, down, env, ctx)
  end

  defp await_phase(pid, ref, down, env, ctx) do
    receive do
      {^ref, status, env} ->
        Process.demonitor(down, [:flush])
        {status, env}

      {:DOWN, ^down, :process, _pid, reason} ->
        IO.puts(:stderr, "error: the #{ctx.phase} phase crashed: #{inspect(reason)}")
        {:crashed, env}

      :perflang_interrupt ->
        Process.exit(pid, :kill)
        Process.demonitor(down, [:flush])
        {:interrupted, env}
    after
      limit(ctx) ->
        Process.exit(pid, :kill)
        Process.demonitor(down, [:flush])
        {:limit, env}
    end
  end

  defp limit(%{phase: phase, rt: rt}) when phase in [:setup, :cleanup], do: rt.phase_limit
  defp limit(_ctx), do: :infinity

  # ---------- What the AST says ----------

  defp tracked(test) do
    lets = for %AST.Let{name: name} <- test.actions.statements, into: MapSet.new(), do: name
    read = vars(test.verify) ++ vars(test.cleanup)
    MapSet.intersection(lets, MapSet.new(read))
  end

  defp vars(%AST.Var{name: name}), do: [name]

  defp vars(%{__struct__: _} = node) do
    node |> Map.from_struct() |> Map.delete(:loc) |> Map.values() |> Enum.flat_map(&vars/1)
  end

  defp vars(list) when is_list(list), do: Enum.flat_map(list, &vars/1)
  defp vars(_other), do: []

  defp runtime(ast, seed, opts) do
    sections = if ast.config, do: ast.config.sections, else: []

    %{
      seed: seed,
      run: 1,
      phase_limit: opts[:phase_limit_ms] || @phase_limit,
      fns: Map.new(ast.functions || [], &{&1.name, &1}),
      targets: for(%AST.Sut{targets: targets} <- sections, target <- targets, into: %{}, do: target(target)),
      monitoring: monitoring(sections),
      output: output(sections)
    }
  end

  defp target(%AST.SutTarget{name: name, settings: settings}) do
    metrics =
      for %AST.TargetMetrics{metrics: metrics} <- settings,
          %AST.MetricSource{name: metric, devices: devices} <- metrics do
        %{name: metric, devices: Enum.map(devices, & &1.value)}
      end

    topics =
      for %AST.TargetTopics{topics: topics} <- settings,
          %AST.Topic{metric: metric, value: value} <- topics,
          into: %{} do
        {metric, value.value}
      end

    {name,
     %{
       base_url: setting(settings, AST.BaseUrl),
       host: setting(settings, AST.Host),
       metrics_port: setting(settings, AST.MetricsPort),
       metrics: metrics,
       topics: topics,
       topics_metrics: Map.keys(topics)
     }}
  end

  defp setting(settings, module) do
    case Enum.find(settings, &(&1.__struct__ == module)) do
      nil -> nil
      %{value: %{value: value}} -> value
      %{value: value} -> value
    end
  end

  defp monitoring(sections) do
    settings = for %AST.Monitoring{settings: settings} <- sections, setting <- settings, do: setting
    interval = setting(settings, AST.MonitorInterval)

    %{
      interval_ms: if(interval, do: round(Values.milliseconds(interval)), else: 1000),
      port: setting(settings, AST.MonitorPort),
      path: setting(settings, AST.MonitorPath) || "/metrics",
      format: setting(settings, AST.MonitorFormat),
      fields: fields(settings, AST.MonitorFields),
      carbon_intensity: setting(settings, AST.CarbonIntensity),
      mqtt: mqtt(settings)
    }
  end

  defp fields(settings, module) do
    for %{__struct__: ^module, fields: fields} <- settings, field <- fields, into: %{} do
      {field.metric, field.path.value}
    end
  end

  defp mqtt(settings) do
    case Enum.find(settings, &match?(%AST.Mqtt{}, &1)) do
      nil ->
        nil

      %AST.Mqtt{settings: mqtt} ->
        %{
          broker: setting(mqtt, AST.MqttBroker),
          qos: setting(mqtt, AST.MqttQos) || 1,
          fields: fields(mqtt, AST.MqttFields)
        }
    end
  end

  defp output(sections) do
    settings = for %AST.Output{settings: settings} <- sections, setting <- settings, do: setting

    %{
      requests: requests(Enum.find(settings, &match?(%AST.RequestsOutput{}, &1))),
      samples: setting(settings, AST.SamplesOutput),
      summary: setting(settings, AST.SummaryOutput)
    }
  end

  defp requests(nil), do: nil

  defp requests(%AST.RequestsOutput{settings: settings}) do
    fields =
      case Enum.find(settings, &match?(%AST.OutputFields{}, &1)) do
        nil -> nil
        %AST.OutputFields{fields: fields} -> Enum.map(fields, & &1.name)
      end

    %{
      file: setting(settings, AST.OutputFile),
      fields: fields,
      include_warmup: setting(settings, AST.IncludeWarmup) == true
    }
  end

  defp load_config(%AST.Load{settings: settings}) do
    warmup = setting(settings, AST.Warmup)
    think = setting(settings, AST.ThinkTime)
    timeout = setting(settings, AST.RequestTimeout)

    %{
      warmup_ms: time(warmup, 0),
      think_ms: time(think, 0),
      timeout_ms: time(timeout, 30_000),
      retry: retry(Enum.find(settings, &match?(%AST.Retry{}, &1))),
      stages: stages(settings),
      curves:
        for(%AST.Curves{definitions: definitions} <- settings, d <- definitions, into: %{}, do: {d.name, d}),
      distribution:
        for(
          %AST.Distribution{entries: entries} <- settings,
          e <- entries,
          do: {e.target, e.percentage.hundredths}
        ),
      stop_ifs: for(%AST.StopIf{condition: condition} <- settings, do: condition)
    }
  end

  defp time(nil, default), do: default
  defp time(%AST.TimeLiteral{} = literal, _default), do: Values.milliseconds(literal)

  defp stages(settings) do
    case Enum.find(settings, &match?(%AST.Stages{}, &1)) do
      nil -> [%AST.HoldStage{users: %AST.UsersLiteral{value: 1}, duration: %AST.IterationsLiteral{value: 1}}]
      %AST.Stages{stages: stages} -> stages
    end
  end

  defp retry(nil), do: %{attempts: 1, delay_ms: 0, backoff: :fixed}

  defp retry(%AST.Retry{entries: entries}) do
    backoff = Enum.find(entries, &match?(%AST.Backoff{}, &1))

    %{
      attempts: setting(entries, AST.Attempts) || 1,
      delay_ms: time(Enum.find_value(entries, &(match?(%AST.Delay{}, &1) && &1.value)), 0),
      backoff: if(backoff, do: backoff.strategy, else: :fixed)
    }
  end
end
