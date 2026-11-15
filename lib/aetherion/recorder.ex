defmodule Aetherion.Recorder do
  @moduledoc """
  What a Test records, and the metrics read from it (C60, C104-C108, C118, C130).

  Every request attempt goes into an ETS table. The last attempt of a request
  waits in the process that made it until the next request or the end of the
  iteration, so a failed assert or check can still mark it (C125, C130).

  Metrics count Actions only, without warmup, and a retried request counts once,
  by its last attempt (C104, C107). Percentiles are exact (C172). A request that
  counts also goes into a compact table and live counters, so stopIf can read
  metrics during the run without copying every record (C58).
  """

  @asserts 1
  @asserts_failed 2
  @checks 3
  @checks_failed 4
  @verify_asserts 5
  @phase_failures 6
  @actions_failures 7

  @live_requests 1
  @live_failed 2
  @live_outcomes %{
    "timeout" => 3,
    "connectionError" => 4,
    "assertFailed" => 5,
    "checkFailed" => 6
  }

  @window_start 1
  @window_end 2
  @warmup_end 3
  @peak_users 4
  @users 5

  @pending {__MODULE__, :pending}

  @counter_count 7

  @doc """
  A new recorder. With `outbox: true`, as on a worker, a request that counts goes into an
  outbox instead, which `take_counted/1` empties for the main server.
  """
  def new(opts \\ []) do
    %{
      requests: :ets.new(:requests, [:ordered_set, :public, write_concurrency: true]),
      counted: :ets.new(:counted, [:duplicate_bag, :public, write_concurrency: true]),
      live: :counters.new(6, [:write_concurrency]),
      failures: :ets.new(:failures, [:set, :public, write_concurrency: true]),
      verify: :ets.new(:verify, [:ordered_set, :public]),
      counters: :counters.new(@counter_count, [:write_concurrency]),
      clock: :atomics.new(5, signed: true),
      outbox:
        if(Keyword.get(opts, :outbox, false),
          do: :ets.new(:outbox, [:ordered_set, :public, write_concurrency: true])
        )
    }
  end

  def delete(recorder) do
    for table <- [recorder.requests, recorder.counted, recorder.failures, recorder.verify, recorder.outbox],
        table != nil,
        do: :ets.delete(table)

    :ok
  end

  @doc "Milliseconds on the monotonic clock."
  def now, do: System.monotonic_time(:microsecond) / 1000

  def start_window(recorder, warmup_ms) do
    start = System.monotonic_time(:microsecond)
    :atomics.put(recorder.clock, @window_start, start)
    :atomics.put(recorder.clock, @warmup_end, start + trunc(warmup_ms * 1000))
  end

  def end_window(recorder), do: :atomics.put(recorder.clock, @window_end, System.monotonic_time(:microsecond))

  def warmup?(recorder), do: System.monotonic_time(:microsecond) < :atomics.get(recorder.clock, @warmup_end)

  @doc "Milliseconds of warmup still to come, for a worker that joins the window now."
  def warmup_left(recorder),
    do: max(:atomics.get(recorder.clock, @warmup_end) - System.monotonic_time(:microsecond), 0) / 1000

  @doc "The measured window on the monotonic clock, in milliseconds: Actions outside warmup (C162)."
  def window(recorder) do
    from = :atomics.get(recorder.clock, @warmup_end)

    to =
      case :atomics.get(recorder.clock, @window_end) do
        0 -> System.monotonic_time(:microsecond)
        value -> value
      end

    {from / 1000, to / 1000}
  end

  def users(recorder, count) do
    :atomics.put(recorder.clock, @users, count)
    if count > :atomics.get(recorder.clock, @peak_users), do: :atomics.put(recorder.clock, @peak_users, count)
  end

  def peak_users(recorder), do: :atomics.get(recorder.clock, @peak_users)
  def current_users(recorder), do: :atomics.get(recorder.clock, @users)

  # ---------- Requests ----------

  @doc "Stores a request attempt. `last` holds it back so that an assert can still mark it."
  def attempt(recorder, record, last?) do
    flush()

    if last?,
      do: Process.put(@pending, {recorder, record}),
      else: insert(recorder, %{record | last: false})
  end

  @doc "Stores the attempt held back, at the end of an iteration or a phase."
  def flush do
    case Process.delete(@pending) do
      nil -> :ok
      {recorder, record} -> insert(recorder, record)
    end
  end

  defp insert(recorder, record) do
    :ets.insert(recorder.requests, {{record.at, :erlang.unique_integer([:monotonic])}, record})
    if counted?(record), do: count(recorder, record)
  end

  defp counted?(%{phase: "Actions", last: true, warmup: false}), do: true
  defp counted?(_record), do: false

  defp count(recorder, record) do
    row = {record.outcome, record.latency, record.target, record.method, record.path}

    case recorder.outbox do
      nil -> count_row(recorder, row)
      outbox -> :ets.insert(outbox, {:erlang.unique_integer([:monotonic]), row})
    end
  end

  defp count_row(recorder, {outcome, _latency, _target, _method, _path} = row) do
    :ets.insert(recorder.counted, row)
    :counters.add(recorder.live, @live_requests, 1)

    if outcome != "ok" do
      :counters.add(recorder.live, @live_failed, 1)

      case Map.fetch(@live_outcomes, outcome) do
        {:ok, index} -> :counters.add(recorder.live, index, 1)
        :error -> :ok
      end
    end
  end

  # ---------- Workers ----------

  @doc """
  Empties the outbox of a worker's recorder. Each row is taken on its own, so a row a user
  inserts meanwhile stays for the next call.
  """
  def take_counted(%{outbox: outbox}) do
    outbox
    |> :ets.select([{{:"$1", :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn key ->
      case :ets.take(outbox, key) do
        [{_key, row}] -> [row]
        [] -> []
      end
    end)
  end

  @doc "Counts the rows a worker sent, as if its users had made the requests here."
  def merge_counted(recorder, rows), do: Enum.each(rows, &count_row(recorder, &1))

  @doc """
  What a worker's recorder holds besides the outbox, for the main server: the counters, the
  failures, and with `requests?` every request attempt, its `at` moved onto the main
  server's clock by `offset_ms`.
  """
  def export(recorder, offset_ms, requests?) do
    %{
      requests:
        if(requests?,
          do:
            for({_key, record} <- :ets.tab2list(recorder.requests), do: %{record | at: record.at + offset_ms}),
          else: []
        ),
      counters: for(index <- 1..@counter_count, do: :counters.get(recorder.counters, index)),
      failures: :ets.tab2list(recorder.failures)
    }
  end

  @doc "Adds what `export/3` gave on a worker."
  def merge(recorder, %{requests: requests, counters: counters, failures: failures}) do
    for record <- requests,
        do: :ets.insert(recorder.requests, {{record.at, :erlang.unique_integer([:monotonic])}, record})

    for {value, index} <- Enum.with_index(counters, 1),
        value != 0,
        do: :counters.add(recorder.counters, index, value)

    for {key, count} <- failures,
        do: :ets.update_counter(recorder.failures, key, count, {key, 0})

    :ok
  end

  # A request that is not ok keeps its outcome and counts once (C125, C130).
  defp mark(outcome) do
    case Process.get(@pending) do
      {recorder, %{outcome: "ok", phase: "Actions"} = record} ->
        Process.put(@pending, {recorder, %{record | outcome: outcome}})

      _ ->
        :ok
    end
  end

  # ---------- Asserts and checks (C116-C118, C129, C130) ----------

  def assert_passed(recorder, phase, warmup?) do
    unless warmup? do
      :counters.add(recorder.counters, @asserts, 1)
      if phase == :verify, do: :counters.add(recorder.counters, @verify_asserts, 1)
    end
  end

  def assert_failed(recorder, phase, node, warmup?) do
    if phase == :actions, do: mark("assertFailed")

    unless warmup? do
      :counters.add(recorder.counters, @asserts, 1)
      :counters.add(recorder.counters, @asserts_failed, 1)
      if phase == :verify, do: :counters.add(recorder.counters, @verify_asserts, 1)

      index = if phase == :actions, do: @actions_failures, else: @phase_failures
      :counters.add(recorder.counters, index, 1)
      failure(recorder, "assert", phase, node)
    end
  end

  def check_passed(recorder, warmup?) do
    unless warmup?, do: :counters.add(recorder.counters, @checks, 1)
  end

  def check_failed(recorder, phase, node, warmup?) do
    if phase == :actions, do: mark("checkFailed")

    unless warmup? do
      :counters.add(recorder.counters, @checks, 1)
      :counters.add(recorder.counters, @checks_failed, 1)
      failure(recorder, "check", phase, node)
    end
  end

  defp failure(recorder, kind, phase, %{loc: {line, column}}) do
    :ets.update_counter(recorder.failures, {kind, phase, line, column}, 1, {{kind, phase, line, column}, 0})
  end

  @doc "A Verify assert or check with its values, for the report (C121, C131)."
  def verify_result(recorder, entry) do
    :ets.insert(recorder.verify, {:erlang.unique_integer([:monotonic]), entry})
  end

  def verify_results(recorder) do
    for {_key, entry} <- :ets.tab2list(recorder.verify), do: entry
  end

  def failures(recorder) do
    for {{kind, phase, line, column}, count} <- :ets.tab2list(recorder.failures) do
      %{kind: kind, phase: phase, line: line, column: column, count: count}
    end
  end

  @doc "The result of the Test (C117): every phase but Actions decides, and Actions when Verify has no criteria."
  def result(recorder) do
    phase_failures = :counters.get(recorder.counters, @phase_failures)
    actions_failures = :counters.get(recorder.counters, @actions_failures)
    criteria = :counters.get(recorder.counters, @verify_asserts)

    if phase_failures > 0 or (criteria == 0 and actions_failures > 0), do: :failed, else: :passed
  end

  # ---------- Metrics ----------

  @doc "All request attempts in time order, for the requests file (C120)."
  def records(recorder) do
    for {_key, record} <- :ets.tab2list(recorder.requests), do: record
  end

  @doc "Everything the request metrics read: the totals, each endpoint (C135) and each target (C176)."
  def snapshot(recorder) do
    counted = :ets.tab2list(recorder.counted)
    seconds = seconds(recorder)

    %{
      totals: stats(counted, seconds),
      # A standalone http call has no target (C112).
      targets:
        counted
        |> Enum.group_by(fn {_outcome, _latency, target, _method, _path} -> target end)
        |> Map.delete(nil)
        |> Map.new(fn {target, rows} -> {target, stats(rows, seconds)} end),
      endpoints:
        counted
        |> Enum.group_by(fn {_outcome, _latency, target, method, path} -> {target, method, path} end)
        |> Enum.map(fn {{target, method, path}, rows} ->
          Map.merge(%{target: target, method: method, url: path}, stats(rows, seconds))
        end)
        |> Enum.sort_by(&{to_string(&1.target), &1.url, &1.method})
    }
  end

  defp seconds(recorder) do
    {from, to} = window(recorder)
    max(to - from, 0) / 1000
  end

  defp stats(rows, seconds) do
    latencies = latencies(rows)
    total = length(rows)
    failed = Enum.count(rows, &(elem(&1, 0) != "ok"))

    %{
      requests: total,
      latency: latency(latencies),
      latencies: latencies,
      throughput: if(seconds > 0, do: total / seconds, else: 0.0),
      errors: %{
        rate: if(total > 0, do: failed * 100 / total, else: 0.0),
        count: failed,
        timeouts: Enum.count(rows, &(elem(&1, 0) == "timeout")),
        connectionErrors: Enum.count(rows, &(elem(&1, 0) == "connectionError")),
        assertFailures: Enum.count(rows, &(elem(&1, 0) == "assertFailed")),
        checkFailures: Enum.count(rows, &(elem(&1, 0) == "checkFailed"))
      }
    }
  end

  # Timeouts and connection errors have no latency (C108).
  defp latencies(rows) do
    rows
    |> Enum.filter(&(elem(&1, 0) in ["ok", "failed", "assertFailed", "checkFailed"]))
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
  end

  @doc "The sorted latencies so far, for stopIf. Only percentiles need them."
  def live_latencies(recorder) do
    recorder.counted
    |> :ets.select([{{:"$1", :"$2", :_, :_, :_}, [], [{{:"$1", :"$2"}}]}])
    |> latencies()
  end

  @doc "The totals so far, from the counters: stopIf reads these once a second (C58)."
  def live(recorder) do
    total = :counters.get(recorder.live, @live_requests)
    failed = :counters.get(recorder.live, @live_failed)
    seconds = seconds(recorder)
    outcome = &:counters.get(recorder.live, @live_outcomes[&1])

    %{
      requests: total,
      throughput: if(seconds > 0, do: total / seconds, else: 0.0),
      errors: %{
        rate: if(total > 0, do: failed * 100 / total, else: 0.0),
        count: failed,
        timeouts: outcome.("timeout"),
        connectionErrors: outcome.("connectionError"),
        assertFailures: outcome.("assertFailed"),
        checkFailures: outcome.("checkFailed")
      }
    }
  end

  defp latency([]), do: nil

  defp latency(sorted) do
    %{
      p50: percentile(sorted, 50),
      p90: percentile(sorted, 90),
      p95: percentile(sorted, 95),
      p99: percentile(sorted, 99),
      mean: Enum.sum(sorted) / length(sorted),
      min: hd(sorted),
      max: List.last(sorted)
    }
  end

  @doc "The latency measurements of a sorted list, or nil when it is empty."
  def latency_stats(sorted), do: latency(sorted)

  @doc "The nearest-rank percentile of a sorted list (C172)."
  def percentile([], _n), do: nil

  def percentile(sorted, n) do
    rank = max(ceil(n / 100 * length(sorted)), 1)
    Enum.at(sorted, rank - 1)
  end

  def rate(recorder, :asserts), do: rate(recorder, @asserts_failed, @asserts)
  def rate(recorder, :checks), do: rate(recorder, @checks_failed, @checks)

  defp rate(recorder, failed, total) do
    case :counters.get(recorder.counters, total) do
      0 -> 0.0
      count -> :counters.get(recorder.counters, failed) * 100 / count
    end
  end

  def failed(recorder, :asserts), do: :counters.get(recorder.counters, @asserts_failed)
  def failed(recorder, :checks), do: :counters.get(recorder.counters, @checks_failed)
end
