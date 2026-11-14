defmodule Aetherion.Report do
  @moduledoc """
  What a run leaves behind: the requests and samples files (C120, C173), the
  summary (C121) and the console report (C131), for every run and across the
  runs (C180).
  """

  alias Aetherion.Values

  @request_fields ~w(time run test phase virtualUser iteration target method url status latency outcome attempt)a

  # ---------- Files (C119) ----------

  @doc "A path to write to: folders are created, and an existing file is kept (C119)."
  def path(file) do
    File.mkdir_p!(Path.dirname(file))

    if File.exists?(file) do
      stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%S")
      unique(Path.rootname(file) <> "-" <> stamp, Path.extname(file), 0)
    else
      file
    end
  end

  defp unique(base, extension, 0) do
    candidate = base <> extension
    if File.exists?(candidate), do: unique(base, extension, 1), else: candidate
  end

  defp unique(base, extension, n) do
    candidate = "#{base}-#{n}#{extension}"
    if File.exists?(candidate), do: unique(base, extension, n + 1), else: candidate
  end

  def open(output) do
    %{
      requests: output.requests && %{output.requests | file: path(output.requests.file)},
      samples: output.samples && path(output.samples),
      summary: output.summary && path(output.summary)
    }
  end

  @doc "Appends the request attempts of a Test in one run: one JSON object per line, in the order of C120."
  def write_requests(nil, _records, _run), do: :ok

  def write_requests(%{file: file, fields: fields, include_warmup: include_warmup}, records, run) do
    chosen = if fields, do: Enum.filter(@request_fields, &(to_string(&1) in fields)), else: @request_fields

    lines =
      for record <- records, include_warmup or not record.warmup do
        record = Map.put(record, :run, run)
        pairs = Enum.map(chosen, &{&1, Map.fetch!(record, &1)})
        pairs = if include_warmup, do: pairs ++ [warmup: record.warmup], else: pairs
        [object(pairs), "\n"]
      end

    File.write!(file, lines, [:append])
  end

  @doc "Appends the samples of a Test in one run (C173)."
  def write_samples(nil, _samples, _run), do: :ok

  def write_samples(file, samples, run) do
    lines =
      for sample <- samples do
        sample = Map.put(sample, :run, run)
        [object(Enum.map(~w(time run target metric value phase)a, &{&1, Map.fetch!(sample, &1)})), "\n"]
      end

    File.write!(file, lines, [:append])
  end

  # JSON maps have no order, and C120 fixes one.
  defp object(pairs) do
    [
      "{",
      pairs
      |> Enum.map(fn {key, value} -> [JSON.encode!(to_string(key)), ":", JSON.encode!(value)] end)
      |> Enum.intersperse(","),
      "}"
    ]
  end

  # ---------- Summary (C121) ----------

  def write_summary(nil, _summary), do: :ok
  def write_summary(file, summary), do: File.write!(file, JSON.encode!(summary) <> "\n")

  # Layout version 3: every run with its Tests, and each Test across the runs (C180).
  def summary(run) do
    %{
      version: 3,
      suite: run.suite,
      seed: run.seed,
      startedAt: DateTime.to_iso8601(run.started_at),
      durationMs: run.duration_ms,
      result: result(run),
      experiment: %{count: run.plan.count, discard: run.plan.discard, cooldownMs: run.plan.cooldown_ms},
      runs: Enum.map(run.runs, &run_summary/1),
      tests: Enum.map(run.tests, &experiment_test/1)
    }
  end

  @doc "passed, failed or aborted: for the whole experiment, or for one run."
  def result(%{status: :ok, tests: tests}) do
    if Enum.any?(tests, &(&1.result == :failed)), do: "failed", else: "passed"
  end

  def result(_run), do: "aborted"

  defp run_summary(run) do
    %{
      run: run.run,
      seed: run.seed,
      discarded: run.discarded,
      startedAt: DateTime.to_iso8601(run.started_at),
      durationMs: run.duration_ms,
      result: result(run),
      tests: Enum.map(run.tests, &test_summary/1)
    }
  end

  defp experiment_test(test) do
    %{
      name: test.name,
      result: to_string(test.result),
      runs: %{counted: test.counted, passed: test.passed, failed: test.failed},
      aggregate: test.aggregate
    }
  end

  @doc "One Test in one run, as in the summary (C121)."
  def test_summary(test) do
    totals = test.snapshot.totals

    %{
      name: test.name,
      result: to_string(test.result),
      stoppedBy: test.stopped_by,
      metrics:
        %{
          requests: totals.requests,
          latency: totals.latency,
          throughput: %{perSecond: totals.throughput},
          errors: totals.errors,
          asserts: test.asserts,
          checks: test.checks
        }
        |> Map.merge(test.energy),
      endpoints: Enum.map(test.snapshot.endpoints, &endpoint/1),
      targets: targets(test),
      loadGenerator: test.load_generator,
      verify: Enum.map(test.verify, &verify/1),
      failures: Enum.map(test.failures, &failure/1)
    }
  end

  defp endpoint(endpoint), do: Map.delete(endpoint, :latencies)

  # Every measured target and every target that takes requests, by name. A
  # target that takes requests has its request metrics (C176), others null.
  defp targets(test) do
    monitored = Map.new(test.targets, &{&1.name, &1})
    takes_requests = Map.get(test, :request_targets, []) ++ Map.keys(test.snapshot.targets)

    for name <- Enum.sort(Enum.uniq(Map.keys(monitored) ++ takes_requests)) do
      entry = Map.get(monitored, name, %{name: name, readings: %{}, energy: nil})
      metrics = if name in takes_requests, do: target_metrics(test.snapshot.targets[name])
      Map.put(entry, :metrics, metrics)
    end
  end

  defp target_metrics(nil), do: %{requests: 0, latency: nil, throughput: %{perSecond: 0.0}, errors: nil}

  defp target_metrics(stats) do
    %{
      requests: stats.requests,
      latency: stats.latency,
      throughput: %{perSecond: stats.throughput},
      errors: stats.errors
    }
  end

  defp verify(entry) do
    %{
      kind: to_string(entry.kind),
      source: entry.source,
      line: entry.line,
      column: entry.column,
      values: Map.new(entry.values, fn {text, value} -> {text, Values.plain(value)} end),
      passed: entry.passed
    }
  end

  defp failure(entry), do: %{entry | phase: phase_name(entry.phase)}

  defp phase_name(phase), do: phase |> to_string() |> String.capitalize()

  # ---------- Console (C131) ----------

  # One run prints as it always has; several runs print a line per Test and
  # run, then each Test across the counted runs (C180).
  def console(run, device \\ :stdio)

  def console(%{plan: %{count: 1}} = run, device) do
    for single <- run.runs, do: Enum.each(single.tests, &console_test(&1, device))
    IO.puts(device, "\nSeed #{run.seed}, #{result(run)}")
    if run.message, do: IO.puts(device, run.message)
  end

  def console(run, device) do
    Enum.each(run.runs, &console_run(&1, run.plan.count, device))
    Enum.each(run.tests, &console_experiment_test(&1, device))
    discarded = if run.plan.discard > 0, do: " (#{run.plan.discard} discarded)", else: ""

    IO.puts(
      device,
      "\nSeed #{run.seed}, #{length(run.runs)} of #{run.plan.count} runs#{discarded}, #{result(run)}"
    )

    if run.message, do: IO.puts(device, run.message)
  end

  defp console_run(run, count, device) do
    discarded = if run.discarded, do: ", discarded", else: ""
    IO.puts(device, "\nRun #{run.run} of #{count} (seed #{run.seed}#{discarded}): #{result(run)}")

    for test <- run.tests do
      totals = test.snapshot.totals
      p95 = if totals.latency, do: ", p95 #{number(totals.latency.p95)}ms", else: ""

      IO.puts(
        device,
        "  Test #{test.name}: #{String.upcase(to_string(test.result))}, #{totals.requests} requests, " <>
          "#{number(totals.throughput)}/s, #{number(totals.errors.rate)}% errors#{p95}"
      )

      for entry <- test.verify, not entry.passed do
        values = Enum.map_join(entry.values, ", ", fn {text, value} -> "#{text} = #{shown(value)}" end)

        IO.puts(
          device,
          "    FAILED #{entry.kind} #{entry.source}" <> if(values == "", do: "", else: "  (#{values})")
        )
      end
    end
  end

  defp console_experiment_test(test, device) do
    IO.puts(
      device,
      "\nTest #{test.name}: #{String.upcase(to_string(test.result))}, " <>
        "passed in #{test.passed} of #{test.counted} counted runs"
    )

    metrics = test.aggregate.metrics || %{}
    IO.puts(device, "  mean ± 95% confidence interval (coefficient of variation)")
    estimate(device, "requests", metrics[:requests], "")
    estimate(device, "throughput", get_in(metrics, [:throughput, :perSecond]), "/s")
    estimate(device, "errors", get_in(metrics, [:errors, :rate]), "%")

    for measurement <- ~w(p50 p95 p99)a do
      estimate(device, "latency #{measurement}", get_in(metrics, [:latency, measurement]), "ms")
    end

    for endpoint <- test.aggregate.endpoints do
      estimate(device, "#{endpoint_name(endpoint)} p95", get_in(endpoint, [:latency, :p95]), "ms")
    end

    estimate(device, "energy", get_in(metrics, [:energy, :total]), "J")
    estimate(device, "power", get_in(metrics, [:power, :mean]), "W")

    for target <- test.aggregate.targets, {metric, stats} <- Enum.sort(target[:readings] || %{}) do
      unit = if metric == "power", do: "W", else: "%"
      estimate(device, "#{target.name} #{metric} mean", stats[:mean], unit)
    end

    for {metric, stats} <- Enum.sort(test.aggregate.loadGenerator || %{}) do
      estimate(device, "loadGenerator #{metric} mean", stats[:mean], "%")
    end
  end

  defp estimate(_device, _label, nil, _unit), do: :ok

  defp estimate(device, label, %{sd: nil} = stats, unit),
    do: IO.puts(device, "  #{label} #{number(stats.mean)}#{unit} (n=#{stats.n})")

  defp estimate(device, label, stats, unit) do
    half = stats.ci95.high - stats.mean
    cv = if stats.cv, do: ", CV #{number(stats.cv)}%", else: ""
    IO.puts(device, "  #{label} #{number(stats.mean)}#{unit} ± #{number(half)}#{unit} (n=#{stats.n}#{cv})")
  end

  defp console_test(test, device) do
    totals = test.snapshot.totals
    IO.puts(device, "\nTest #{test.name}: #{String.upcase(to_string(test.result))}")
    if test.stopped_by, do: IO.puts(device, "  stopped by stopIf #{test.stopped_by}")

    IO.puts(
      device,
      "  #{totals.requests} requests, #{number(totals.throughput)}/s, " <>
        "#{number(totals.errors.rate)}% errors (#{totals.errors.count})"
    )

    if totals.latency, do: IO.puts(device, "  latency #{latency(totals.latency)}")

    # With one target the totals already say it all (C176).
    request_targets = Map.get(test, :request_targets, [])

    if length(request_targets) > 1 do
      for name <- request_targets do
        IO.puts(device, "  #{name}: #{target_line(test.snapshot.targets[name])}")
      end
    end

    for endpoint <- test.snapshot.endpoints do
      IO.puts(
        device,
        "  #{endpoint_name(endpoint)}: #{endpoint.requests} requests, " <>
          "#{number(endpoint.errors.rate)}% errors" <>
          if(endpoint.latency, do: ", p95 #{number(endpoint.latency.p95)}ms", else: "")
      )
    end

    # Each measured target: its readings (C160), then its energy (C161).
    for target <- test.targets do
      for {metric, stats} <- Enum.sort(target.readings) do
        IO.puts(device, "  #{target.name} #{metric} #{reading(metric, stats)}")
      end

      if target.energy do
        total = if target.energy.total, do: "#{number(target.energy.total)}J", else: "no value"

        IO.puts(
          device,
          "  #{target.name} energy #{total} (#{target.energy.source}, #{target.energy.samples} samples)"
        )
      end
    end

    # The engine's own machine, read without an agent (C160).
    for {metric, stats} <- Enum.sort(Map.get(test, :load_generator) || %{}) do
      IO.puts(device, "  loadGenerator #{metric} #{reading(metric, stats)}")
    end

    for entry <- test.verify do
      values = Enum.map_join(entry.values, ", ", fn {text, value} -> "#{text} = #{shown(value)}" end)
      status = if entry.passed, do: "passed", else: "FAILED"

      IO.puts(
        device,
        "  #{status} #{entry.kind} #{entry.source}" <> if(values == "", do: "", else: "  (#{values})")
      )
    end

    for failure <- test.failures, failure.phase != :verify do
      IO.puts(
        device,
        "  #{failure.count} failed #{failure.kind} in #{phase_name(failure.phase)} at #{failure.line}:#{failure.column}"
      )
    end
  end

  defp target_line(nil), do: "0 requests"

  defp target_line(stats) do
    "#{stats.requests} requests, #{number(stats.throughput)}/s, " <>
      "#{number(stats.errors.rate)}% errors (#{stats.errors.count})" <>
      if(stats.latency,
        do: ", " <> Enum.map_join(~w(p50 p95 p99)a, " ", &"#{&1} #{number(stats.latency[&1])}ms"),
        else: ""
      )
  end

  # Power is in watts, every other reading a Percentage (C160).
  defp reading(_metric, %{samples: 0}), do: "no value (0 samples)"

  defp reading(metric, stats) do
    unit = if metric == "power", do: "W", else: "%"
    "mean #{number(stats.mean)}#{unit} max #{number(stats.max)}#{unit} (#{stats.samples} samples)"
  end

  defp shown(nil), do: "no value"
  defp shown(value), do: Values.show(value)

  defp endpoint_name(%{target: nil, method: method, url: url}), do: "#{method} #{url}"
  defp endpoint_name(%{target: target, method: method, url: url}), do: "#{method} #{target}#{url}"

  defp latency(latency) do
    Enum.map_join(~w(p50 p90 p95 p99 mean min max)a, " ", &"#{&1} #{number(latency[&1])}ms")
  end

  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp number(value), do: to_string(value)
end
