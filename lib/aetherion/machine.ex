defmodule Aetherion.Machine do
  @moduledoc """
  Reads cpu, mem, disk and net of this machine from /proc, for the aetherion
  agent (C185). The definitions are the ones the engine applies to
  node_exporter (C158, C174, C186), so a target reads the same with either agent:

    * cpu: `100 * (1 - change of idle / change of all modes)` between two
      samples, over the selected cores, or over all of them. The modes are
      node_exporter's: user, nice, system, idle, iowait, irq, softirq and
      steal; guest time is already part of user.
    * mem: `100 * (1 - MemAvailable / MemTotal)`.
    * disk: the share of the time passed spent on I/O, the mean over the
      selected devices, or over the whole disks node_exporter reports by
      default (no partitions, ram, loop or floppy devices).
    * net: received plus sent bytes per second, summed over the selected
      interfaces, or over every interface but loopback and the virtual ones
      of containers, bridges and tunnels, which would count the same bytes
      again.

  cpu, disk and net are changes of counters, so they need the sample before:
  the first sample has only mem. A counter that went back, such as an
  interface that was recreated, gives no value for that device once.
  """

  @files %{
    "cpu" => "/proc/stat",
    "mem" => "/proc/meminfo",
    "disk" => "/proc/diskstats",
    "net" => "/proc/net/dev"
  }

  # node_exporter's default for diskstats: whole disks only.
  @not_disks ~r/^(z?ram|loop|fd|(h|s|v|xv)d[a-z]|nvme\d+n\d+p)\d+$/

  # Loopback and the virtual interfaces of containers, bridges and tunnels.
  @virtual ~r/^(lo|veth.*|docker\d+|br-.+|virbr\d+.*|vnet\d+|cni\d+|flannel\..+|cali.+|cilium_.+|kube-.+|weave.*|vxlan.+|tun\d+|tap\d+|wg\d+|tunl\d+|sit\d+|ip6tnl\d+|gre\d+|gretap\d+|erspan\d+)$/

  @doc "The metrics the agent measures."
  def metrics, do: Map.keys(@files)

  @doc """
  Samples `metrics`, a list of `%{name: metric, devices: devices}`, at `now` in
  milliseconds. Returns `{[{metric, value}], previous}`, where `previous` goes
  into the next call.
  """
  def sample(metrics, previous, now) do
    texts =
      for %{name: name} <- metrics, path = @files[name], into: %{} do
        {name, read(path)}
      end

    readings(metrics, texts, previous, now)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  @doc "Like `sample/3`, with the text of each metric's file in `texts`, `%{metric => text}`."
  def readings(metrics, texts, previous, now) do
    Enum.reduce(metrics, {[], previous}, fn %{name: metric, devices: devices}, {values, previous} ->
      case reading(metric, texts[metric], devices, previous[metric], now) do
        {nil, state} -> {values, Map.put(previous, metric, state)}
        {value, state} -> {values ++ [{metric, value}], Map.put(previous, metric, state)}
      end
    end)
  end

  defp reading(_metric, nil, _devices, last, _now), do: {nil, last}

  defp reading("cpu", text, devices, last, _now) do
    case cpu_counters(text, devices) do
      nil ->
        {nil, last}

      {idle, total} = counters ->
        case last do
          {last_idle, last_total} when total > last_total ->
            {(1 - (idle - last_idle) / (total - last_total)) * 100, counters}

          _ ->
            {nil, counters}
        end
    end
  end

  defp reading("mem", text, _devices, _last, _now), do: {mem(text), nil}

  defp reading("disk", text, devices, last, now) do
    counters = disk_counters(text, devices)

    # io_ticks are milliseconds, so the change per millisecond passed is the busy share.
    case changes(counters, last) do
      {[_ | _] = deltas, last_now} when now > last_now ->
        {Enum.sum(deltas) / (now - last_now) / length(deltas) * 100, {counters, now}}

      _ ->
        {nil, {counters, now}}
    end
  end

  defp reading("net", text, devices, last, now) do
    rate(net_counters(text, devices), last, now)
  end

  defp reading(_metric, _text, _devices, last, _now), do: {nil, last}

  @doc """
  Bytes per second from counters of bytes, `%{device => bytes}`, and the state of
  the reading before: `{value or nil, state}`. Summed over the devices in both.
  """
  def rate(counters, last, now) do
    case changes(counters, last) do
      {[_ | _] = deltas, last_now} when now > last_now ->
        {Enum.sum(deltas) / ((now - last_now) / 1000), {counters, now}}

      _ ->
        {nil, {counters, now}}
    end
  end

  # The change of every counter that was there before and did not go back.
  defp changes(counters, {last, last_now}) do
    deltas =
      for {device, value} <- counters,
          before = last[device],
          before != nil and value >= before,
          do: value - before

    {deltas, last_now}
  end

  defp changes(_counters, _last), do: {[], nil}

  @doc "`{idle, total}` of the selected cores in /proc/stat, in clock ticks, or nil."
  def cpu_counters(text, devices) do
    wanted = MapSet.new(devices, &"cpu#{&1}")

    rows =
      for line <- String.split(text, "\n"),
          [name | fields] <- [String.split(line)],
          if(devices == [], do: name == "cpu", else: MapSet.member?(wanted, name)),
          do: fields |> Enum.take(8) |> Enum.map(&String.to_integer/1)

    case rows do
      [] -> nil
      rows -> {rows |> Enum.map(&Enum.at(&1, 3)) |> Enum.sum(), rows |> Enum.map(&Enum.sum/1) |> Enum.sum()}
    end
  end

  @doc "The share of memory in use from /proc/meminfo, or nil."
  def mem(text) do
    with [_, total] <- Regex.run(~r/MemTotal:\s+(\d+)/, text),
         [_, available] <- Regex.run(~r/MemAvailable:\s+(\d+)/, text),
         total when total > 0 <- String.to_integer(total) do
      (1 - String.to_integer(available) / total) * 100
    else
      _ -> nil
    end
  end

  @doc "The milliseconds spent on I/O of each selected device in /proc/diskstats."
  def disk_counters(text, devices) do
    for line <- String.split(text, "\n"),
        [_major, _minor, name | stats] <- [String.split(line)],
        length(stats) >= 10,
        if(devices == [], do: not Regex.match?(@not_disks, name), else: name in devices),
        into: %{},
        do: {name, String.to_integer(Enum.at(stats, 9))}
  end

  @doc "Received plus sent bytes of each selected interface in /proc/net/dev."
  def net_counters(text, devices) do
    for line <- String.split(text, "\n"),
        [name, counters] <- [String.split(line, ":", parts: 2)],
        name = String.trim(name),
        fields = String.split(counters),
        length(fields) >= 9,
        interface?(name, devices),
        into: %{},
        do: {name, String.to_integer(Enum.at(fields, 0)) + String.to_integer(Enum.at(fields, 8))}
  end

  @doc "Whether net covers an interface: one of `devices`, or with none every physical one."
  def interface?(name, []), do: is_binary(name) and not Regex.match?(@virtual, name)
  def interface?(name, devices), do: name in devices
end
