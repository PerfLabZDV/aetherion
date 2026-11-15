defmodule Aetherion.Monitor do
  @moduledoc """
  Samples the machines of a Test (C158-C164).

  An agent is scraped once per interval, an MQTT message is a sample when it
  arrives, and the load generator is read locally. Sampling runs from Setup to
  Cleanup; readings and energy use only the samples inside the measured window
  (C162). Every sample is kept in an ETS table, for the samples file (C173).

  With workers the load generators are the workers (C183): this machine is not
  sampled, and each worker sends its samples, kept as the target
  `loadGenerator.<worker>`.
  """

  alias Aetherion.{Http, Recorder, Values}

  @load_generator "loadGenerator"

  defmodule Error do
    @moduledoc "A monitoring source that cannot start: the run cannot start (C132)."
    defexception [:message]
  end

  def start(rt, recorder) do
    monitor = %{
      rt: rt,
      recorder: recorder,
      table: :ets.new(:samples, [:ordered_set, :public, write_concurrency: true]),
      phase: :atomics.new(1, []),
      pids: [],
      mqtt: nil
    }

    agents =
      for {name, target} <- rt.targets, agent_metrics(target) != [], do: start_agent(monitor, name, target)

    pids = if rt.workers == [], do: [start_local(monitor) | agents], else: agents

    try do
      %{monitor | pids: pids, mqtt: start_mqtt(monitor)}
    rescue
      error in Error ->
        stop(%{monitor | pids: pids})
        delete(monitor)
        reraise error, __STACKTRACE__
    end
  end

  @doc "Stops the sampling and waits for it, so that nothing writes after this returns."
  def stop(%{pids: pids, mqtt: mqtt}) do
    if mqtt, do: stop_mqtt(mqtt)

    for pid <- pids do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end

    :ok
  end

  defp stop_mqtt(pid) do
    ref = Process.monitor(pid)
    send(pid, :perflang_stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      2000 -> Process.exit(pid, :kill)
    end
  end

  def delete(%{table: table}), do: :ets.delete(table)

  @phases %{setup: 1, actions: 2, verify: 3, cleanup: 4}
  @phase_names %{0 => "Setup", 1 => "Setup", 2 => "Actions", 3 => "Verify", 4 => "Cleanup"}

  def set_phase(%{phase: phase}, name), do: :atomics.put(phase, 1, @phases[name])

  defp store(monitor, target, metric, value) do
    store(monitor, target, metric, value, Recorder.now(), DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp store(monitor, target, metric, value, at, wall) do
    key = {at, :erlang.unique_integer([:monotonic])}

    :ets.insert(
      monitor.table,
      {key, target, metric, value, wall, @phase_names[:atomics.get(monitor.phase, 1)]}
    )
  end

  @doc """
  Stores the samples a worker sent, `{worker, metric, value, at, wall}` with `at` on this
  node's clock (C183).
  """
  def store_samples(monitor, samples) do
    for {worker, metric, value, at, wall} <- samples,
        do: store(monitor, worker_target(worker), metric, value, at, wall)

    :ok
  end

  defp worker_target(worker), do: @load_generator <> "." <> worker

  # The names of the workers, the name part of each node name, name@host (C181).
  defp worker_names(%{rt: %{workers: workers}}),
    do: for(node <- workers, do: node |> Atom.to_string() |> String.split("@") |> hd())

  # ---------- Agents (C158, C159) ----------

  defp agent_metrics(target), do: Enum.reject(target.metrics, &(&1.name in target.topics_metrics))

  defp start_agent(monitor, name, target) do
    settings = monitor.rt.monitoring
    host = target.host || URI.parse(target.base_url).host
    url = "http://#{host}:#{target.metrics_port || settings.port}#{settings.path}"

    spawn(fn -> agent_loop(monitor, name, agent_metrics(target), url, %{}) end)
  end

  defp agent_loop(monitor, name, metrics, url, previous) do
    settings = monitor.rt.monitoring
    started = Recorder.now()

    previous =
      case Http.fetch(url, settings.interval_ms) do
        {:ok, body} ->
          {values, previous} = read_agent(body, metrics, settings, previous, started)
          Enum.each(values, fn {metric, value} -> store(monitor, name, metric, value) end)
          previous

        :error ->
          previous
      end

    Process.sleep(max(trunc(settings.interval_ms - (Recorder.now() - started)), 0))
    agent_loop(monitor, name, metrics, url, previous)
  end

  defp read_agent(body, metrics, %{format: "json"} = settings, previous, _now) do
    data =
      case JSON.decode(body) do
        {:ok, value} -> value
        _ -> nil
      end

    values =
      for %{name: metric, devices: devices} <- metrics,
          value = json_reading(data, settings.fields[metric], devices),
          value != nil,
          do: {metric, value}

    {values, previous}
  end

  defp read_agent(body, metrics, settings, previous, now) do
    series = parse_prometheus(body)

    Enum.reduce(metrics, {[], previous}, fn %{name: metric, devices: devices}, {values, previous} ->
      case prometheus_reading(series, metric, settings.fields[metric], devices, previous, now) do
        {nil, previous} -> {values, previous}
        {value, previous} -> {[{metric, value} | values], previous}
      end
    end)
  end

  @doc "Parses the Prometheus text format into `{name, labels, value}`."
  def parse_prometheus(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)/, line) do
        [_, name, labels, value] -> series(name, labels, value)
        _ -> []
      end
    end)
  end

  defp series(name, labels, value) do
    case Float.parse(value) do
      {number, _rest} ->
        pairs = Regex.scan(~r/([a-zA-Z_][a-zA-Z0-9_]*)="([^"]*)"/, labels, capture: :all_but_first)
        [{name, Map.new(pairs, fn [key, label] -> {key, label} end), number}]

      :error ->
        []
    end
  end

  @device_labels %{"cpu" => "cpu", "gpu" => "gpu", "disk" => "device"}

  defp selected?(_labels, _metric, []), do: true

  defp selected?(labels, metric, devices) do
    labels[@device_labels[metric]] in Enum.map(devices, &to_string/1)
  end

  defp prometheus_reading(series, metric, field, devices, previous, _now) when field != nil do
    values = for {^field, labels, value} <- series, selected?(labels, metric, devices), do: value

    cond do
      values == [] -> {nil, previous}
      metric == "power" -> {Enum.sum(values), previous}
      true -> {Enum.sum(values) / length(values), previous}
    end
  end

  # CPU busy share, from the change of the per-mode counters between scrapes.
  defp prometheus_reading(series, "cpu", nil, devices, previous, _now) do
    rows =
      for {"node_cpu_seconds_total", labels, value} <- series,
          selected?(labels, "cpu", devices),
          do: {labels, value}

    idle = rows |> Enum.filter(fn {labels, _value} -> labels["mode"] == "idle" end) |> sum_values()
    total = sum_values(rows)

    case previous["cpu"] do
      {last_idle, last_total} when total > last_total ->
        busy = 1 - (idle - last_idle) / (total - last_total)
        {busy * 100, Map.put(previous, "cpu", {idle, total})}

      _ ->
        {nil, Map.put(previous, "cpu", {idle, total})}
    end
  end

  defp prometheus_reading(series, "mem", nil, _devices, previous, _now) do
    case {gauge(series, "node_memory_MemAvailable_bytes"), gauge(series, "node_memory_MemTotal_bytes")} do
      {available, total} when is_number(available) and is_number(total) and total > 0 ->
        {(1 - available / total) * 100, previous}

      _ ->
        {nil, previous}
    end
  end

  # Disk busy share: the time spent on I/O per time passed.
  defp prometheus_reading(series, "disk", nil, devices, previous, now) do
    rows =
      for {"node_disk_io_time_seconds_total", labels, value} <- series,
          selected?(labels, "disk", devices),
          do: value

    total = Enum.sum(rows)

    case previous["disk"] do
      {last_total, last_now} when rows != [] and now > last_now ->
        busy = (total - last_total) / ((now - last_now) / 1000) / length(rows)
        {busy * 100, Map.put(previous, "disk", {total, now})}

      _ ->
        {nil, Map.put(previous, "disk", {total, now})}
    end
  end

  defp prometheus_reading(_series, _metric, nil, _devices, previous, _now), do: {nil, previous}

  defp sum_values(rows), do: rows |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp gauge(series, name) do
    Enum.find_value(series, fn
      {^name, _labels, value} -> value
      _ -> nil
    end)
  end

  @doc "The value at a dotted path, narrowed to the selected devices (C159, C163)."
  def json_reading(nil, _path, _devices), do: nil
  def json_reading(_data, nil, _devices), do: nil

  def json_reading(data, path, devices) do
    case dig(data, String.split(path, ".")) do
      number when is_number(number) -> number
      list when is_list(list) -> list |> select_list(devices) |> mean()
      map when is_map(map) -> map |> select_map(devices) |> mean()
      _ -> nil
    end
  end

  defp dig(value, []), do: value
  defp dig(map, [key | rest]) when is_map(map), do: dig(Map.get(map, key), rest)
  defp dig(_value, _path), do: nil

  defp select_list(list, []), do: list
  defp select_list(list, devices), do: for(device <- devices, is_integer(device), do: Enum.at(list, device))
  defp select_map(map, []), do: Map.values(map)
  defp select_map(map, devices), do: for(device <- devices, do: map[to_string(device)])

  defp mean(values) do
    case Enum.filter(values, &is_number/1) do
      [] -> nil
      numbers -> Enum.sum(numbers) / length(numbers)
    end
  end

  # ---------- The load generator (C160) ----------

  defp start_local(monitor) do
    spawn(fn -> local_loop(monitor, nil) end)
  end

  defp local_loop(monitor, previous) do
    {readings, previous} = sample_machine(previous)
    for {metric, value} <- readings, do: store(monitor, @load_generator, metric, value)
    Process.sleep(monitor.rt.monitoring.interval_ms)
    local_loop(monitor, previous)
  end

  @doc """
  Reads cpu and mem of this machine: `{[{metric, value}], previous}`. cpu needs the
  counters of the reading before, so the first reading has only mem.
  """
  def sample_machine(previous) do
    {cpu, previous} = local_cpu(previous)
    readings = [{"cpu", cpu}, {"mem", local_mem()}]
    {for({metric, value} <- readings, value != nil, do: {metric, value}), previous}
  end

  defp local_cpu(previous) do
    with {:ok, text} <- File.read("/proc/stat"),
         ["cpu" | fields] <- text |> String.split("\n") |> hd() |> String.split() do
      numbers = Enum.map(fields, &String.to_integer/1)
      total = Enum.sum(numbers)
      idle = Enum.at(numbers, 3) + Enum.at(numbers, 4, 0)

      cpu =
        case previous do
          {last_idle, last_total} when total > last_total ->
            (1 - (idle - last_idle) / (total - last_total)) * 100

          _ ->
            nil
        end

      {cpu, {idle, total}}
    else
      _ -> {nil, previous}
    end
  end

  defp local_mem do
    with {:ok, text} <- File.read("/proc/meminfo"),
         [_, total] <- Regex.run(~r/MemTotal:\s+(\d+)/, text),
         [_, available] <- Regex.run(~r/MemAvailable:\s+(\d+)/, text) do
      (1 - String.to_integer(available) / String.to_integer(total)) * 100
    else
      _ -> nil
    end
  end

  # ---------- MQTT (C163) ----------

  defp start_mqtt(%{rt: %{monitoring: %{mqtt: nil}}}), do: nil

  defp start_mqtt(%{rt: rt} = monitor) do
    topics =
      for {name, target} <- rt.targets, {metric, topic} <- target.topics, into: %{} do
        {topic, {name, metric}}
      end

    if map_size(topics) == 0 do
      nil
    else
      parent = self()
      ref = make_ref()
      pid = spawn(fn -> mqtt_start(monitor, topics, parent, ref) end)

      receive do
        {^ref, :ok} -> pid
        {^ref, {:error, reason}} -> raise Error, "cannot use the MQTT broker: #{inspect(reason)}"
      after
        10_000 ->
          Process.exit(pid, :kill)
          raise Error, "the MQTT broker did not answer"
      end
    end
  end

  defp mqtt_start(monitor, topics, parent, ref) do
    Process.flag(:trap_exit, true)
    {:ok, _started} = Application.ensure_all_started(:emqtt)
    :logger.set_application_level(:emqtt, :warning)
    settings = monitor.rt.monitoring.mqtt
    uri = URI.parse(settings.broker)

    with {:ok, client} <-
           :emqtt.start_link(
             host: String.to_charlist(uri.host),
             port: uri.port || 1883,
             proto_ver: :v4,
             clean_start: true
           ),
         {:ok, _properties} <- :emqtt.connect(client),
         :ok <- subscribe(client, Map.keys(topics), settings.qos) do
      send(parent, {ref, :ok})
      mqtt_loop(monitor, client, topics, settings.fields)
    else
      {:error, reason} -> send(parent, {ref, {:error, reason}})
    end
  end

  defp subscribe(client, topics, qos) do
    Enum.reduce_while(topics, :ok, fn topic, :ok ->
      case :emqtt.subscribe(client, topic, qos) do
        {:ok, _properties, _codes} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mqtt_loop(monitor, client, topics, fields) do
    receive do
      :perflang_stop ->
        :emqtt.disconnect(client)

      # A retained message is an old value, replayed on subscribing (C163).
      {:publish, %{retain: true}} ->
        mqtt_loop(monitor, client, topics, fields)

      {:publish, %{topic: topic, payload: payload}} ->
        with {target, metric} <- topics[topic],
             value when is_number(value) <- mqtt_value(payload, fields[metric]) do
          store(monitor, target, metric, value)
        end

        mqtt_loop(monitor, client, topics, fields)

      _other ->
        mqtt_loop(monitor, client, topics, fields)
    end
  end

  @doc "The value of an MQTT message: a plain number, or the field of a JSON message (C163)."
  def mqtt_value(payload, nil) do
    case Float.parse(String.trim(payload)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  def mqtt_value(payload, field) do
    case JSON.decode(payload) do
      {:ok, data} -> json_reading(data, field, [])
      _ -> nil
    end
  end

  # ---------- Readings (C160, C161, C162, C164) ----------

  defp samples(monitor, target, metric) do
    {from, to} = Recorder.window(monitor.recorder)

    :ets.select(monitor.table, [
      {{{:"$1", :_}, target, metric, :"$2", :_, :_}, [{:>=, :"$1", from}, {:"=<", :"$1", to}],
       [{{:"$1", :"$2"}}]}
    ])
  end

  defp listing(monitor, metric) do
    for {name, target} <- monitor.rt.targets, Enum.any?(target.metrics, &(&1.name == metric)), do: name
  end

  defp covered(%{rt: %{workers: []}}, :load_generator, _metric), do: [@load_generator]
  defp covered(monitor, :load_generator, _metric), do: Enum.map(worker_names(monitor), &worker_target/1)
  defp covered(_monitor, {:load_generator, worker}, _metric), do: [worker_target(worker)]
  defp covered(monitor, :all, metric), do: listing(monitor, metric)
  defp covered(_monitor, {:target, name}, _metric), do: [name]

  defp wrap("power", value), do: {:power, value}
  defp wrap(_metric, value), do: {:percentage, value}

  @doc "A machine reading. `:error` when a target it covers has no sample in the window (C164)."
  def reading(monitor, source, metric, stat) do
    sets = for name <- covered(monitor, source, metric), do: samples(monitor, name, metric)

    if sets == [] or Enum.any?(sets, &(&1 == [])) do
      :error
    else
      values = sets |> List.flatten() |> Enum.map(&elem(&1, 1))
      value = if stat == "max", do: Enum.max(values), else: Enum.sum(values) / length(values)
      {:ok, wrap(metric, value)}
    end
  end

  # The power samples of a target as steps: each holds until the next, the
  # first back to the start of the window, the last on to its end.
  defp integrate(samples, from, to) do
    [{_first, first_value} | _rest] = samples

    {joules, last_at, last_value} =
      Enum.reduce(samples, {0.0, from, first_value}, fn {at, value}, {joules, last_at, last_value} ->
        {joules + (last_value + value) / 2 * (at - last_at) / 1000, at, value}
      end)

    joules + last_value * (to - last_at) / 1000
  end

  defp energy_total(monitor) do
    {from, to} = Recorder.window(monitor.recorder)
    sets = for name <- listing(monitor, "power"), do: samples(monitor, name, "power")

    if sets == [] or Enum.any?(sets, &(&1 == [])),
      do: :error,
      else: {:ok, sets |> Enum.map(&integrate(&1, from, to)) |> Enum.sum()}
  end

  # The sum of the targets over time, once each has reported.
  defp power_series(monitor) do
    names = listing(monitor, "power")
    sets = for name <- names, do: {name, samples(monitor, name, "power")}

    if sets == [] or Enum.any?(sets, fn {_name, samples} -> samples == [] end) do
      :error
    else
      events =
        sets
        |> Enum.flat_map(fn {name, samples} -> Enum.map(samples, fn {at, value} -> {at, name, value} end) end)

      initial = Map.new(sets, fn {name, [{_at, value} | _rest]} -> {name, value} end)

      {_current, totals} =
        events
        |> Enum.sort()
        |> Enum.reduce({initial, []}, fn {_at, name, value}, {current, totals} ->
          current = Map.put(current, name, value)
          {current, [current |> Map.values() |> Enum.sum() | totals]}
        end)

      {:ok, totals}
    end
  end

  @doc "An energy, power or carbon metric (C161). `:error` with no sample for a target that lists power (C164)."
  def energy_metric(monitor, :energy, measurement, requests) do
    with {:ok, joules} <- energy_total(monitor) do
      case measurement do
        :total ->
          {:ok, {:energy, joules}}

        :perRequest when requests > 0 ->
          {:ok, {:energy, joules / requests}}

        :perUser ->
          case Recorder.peak_users(monitor.recorder) do
            0 -> :error
            users -> {:ok, {:energy, joules / users}}
          end

        _ ->
          :error
      end
    end
  end

  def energy_metric(monitor, :power, measurement, _requests) do
    with {:ok, totals} <- power_series(monitor) do
      value = if measurement == :peak, do: Enum.max(totals), else: Enum.sum(totals) / length(totals)
      {:ok, {:power, value}}
    end
  end

  def energy_metric(%{rt: %{monitoring: %{carbon_intensity: nil}}}, :carbon, _measurement, _requests),
    do: :error

  def energy_metric(monitor, :carbon, measurement, requests) do
    with {:ok, joules} <- energy_total(monitor) do
      grams = joules / 3.6e6 * monitor.rt.monitoring.carbon_intensity

      case measurement do
        :total -> {:ok, {:carbon, grams}}
        :perRequest when requests > 0 -> {:ok, {:carbon, grams / requests}}
        _ -> :error
      end
    end
  end

  # ---------- Reports ----------

  @doc "Each measured target, with its readings, energy and source, for the summary (C121, C161, C164)."
  def report(monitor) do
    {from, to} = Recorder.window(monitor.recorder)

    for {name, target} <- Enum.sort_by(monitor.rt.targets, &elem(&1, 0)), target.metrics != [] do
      readings =
        Map.new(target.metrics, fn %{name: metric} ->
          values = monitor |> samples(name, metric) |> Enum.map(&elem(&1, 1))
          {metric, stats(values)}
        end)

      power = samples(monitor, name, "power")
      listed? = Enum.any?(target.metrics, &(&1.name == "power"))

      %{
        name: name,
        readings: readings,
        energy:
          if listed? do
            %{
              total: if(power != [], do: integrate(power, from, to)),
              source: if("power" in target.topics_metrics, do: "mqtt", else: "agent"),
              samples: length(power)
            }
          end
      }
    end
  end

  defp stats([]), do: %{mean: nil, max: nil, samples: 0}

  defp stats(values) do
    %{mean: Enum.sum(values) / length(values), max: Enum.max(values), samples: length(values)}
  end

  @doc "The load generator's readings, for the summary: of every worker together, with workers (C183)."
  def load_generator(monitor) do
    Map.new(["cpu", "mem"], fn metric ->
      values =
        for target <- covered(monitor, :load_generator, metric),
            {_at, value} <- samples(monitor, target, metric),
            do: value

      {metric, stats(values)}
    end)
  end

  @doc "The readings of each worker, by name, for the summary (C183); none without workers."
  def workers(monitor) do
    for name <- monitor |> worker_names() |> Enum.sort() do
      readings =
        Map.new(["cpu", "mem"], fn metric ->
          {metric, monitor |> samples(worker_target(name), metric) |> Enum.map(&elem(&1, 1)) |> stats()}
        end)

      %{name: name, readings: readings}
    end
  end

  @doc "All samples in time order, for the samples file (C173)."
  def all_samples(monitor) do
    for {_key, target, metric, value, wall, phase} <- :ets.tab2list(monitor.table) do
      %{time: wall, target: target, metric: metric, value: Values.round_to(value), phase: phase}
    end
  end
end
