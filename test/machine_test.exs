defmodule Aetherion.MachineTest do
  use ExUnit.Case, async: true

  alias Aetherion.Machine

  # user nice system idle iowait irq softirq steal guest guest_nice
  defp stat(step) do
    """
    cpu  #{step * 30} 0 #{step * 10} #{step * 50} #{step * 10} 0 0 0 #{step * 99} 0
    cpu0 #{step * 10} 0 0 #{step * 30} 0 0 0 0 0 0
    cpu1 #{step * 20} 0 #{step * 10} #{step * 20} #{step * 10} 0 0 0 0 0
    intr 1 2 3
    """
  end

  @meminfo """
  MemTotal:       1000 kB
  MemFree:         100 kB
  MemAvailable:    250 kB
  """

  # major minor name, then 11 stats; the 10th is the milliseconds spent on I/O.
  defp diskstats(step) do
    """
     259       0 nvme0n1 1 0 0 0 0 0 0 0 0 #{step * 50} 0
     259       1 nvme0n1p1 1 0 0 0 0 0 0 0 0 #{step * 50} 0
       8       0 sda 1 0 0 0 0 0 0 0 0 #{step * 10} 0
       7       0 loop0 1 0 0 0 0 0 0 0 0 #{step * 100} 0
    """
  end

  defp netdev(step) do
    """
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo: #{step * 1_000_000} 1 0 0 0 0 0 0 #{step * 1_000_000} 1 0 0 0 0 0 0
      eth0:#{step * 3000} 1 0 0 0 0 0 0 #{step * 1000} 1 0 0 0 0 0 0
    docker0: #{step * 500} 1 0 0 0 0 0 0 #{step * 500} 1 0 0 0 0 0 0
    veth1a2b: #{step * 500} 1 0 0 0 0 0 0 #{step * 500} 1 0 0 0 0 0 0
    """
  end

  defp texts(step),
    do: %{"cpu" => stat(step), "mem" => @meminfo, "disk" => diskstats(step), "net" => netdev(step)}

  defp metrics(names), do: for({name, devices} <- names, do: %{name: name, devices: devices})

  # Two samples one second apart.
  defp second(names) do
    metrics = metrics(names)
    {first, previous} = Machine.readings(metrics, texts(1), %{}, 1000)
    {readings, _previous} = Machine.readings(metrics, texts(2), previous, 2000)
    {first, Map.new(readings)}
  end

  test "the first sample has only mem; the counters need the one before" do
    {first, readings} = second([{"cpu", []}, {"mem", []}, {"disk", []}, {"net", []}])
    assert first == [{"mem", 75.0}]
    assert Map.keys(readings) == ["cpu", "disk", "mem", "net"]
  end

  test "cpu is the busy share over node_exporter's modes, guest not counted twice (C174)" do
    # Per step: idle 50 of 30 + 10 + 50 + 10 = 100; iowait is busy, guest is left out.
    {_first, readings} = second([{"cpu", []}])
    assert readings["cpu"] == 50.0

    # cpu0: idle 30 of 40; cpu1: idle 20 of 60; together 50 of 100.
    assert {_first, %{"cpu" => 25.0}} = second([{"cpu", [0]}])
    assert {_first, %{"cpu" => 50.0}} = second([{"cpu", [0, 1]}])
  end

  test "disk is the mean busy share over the whole disks, or the selected devices" do
    # nvme0n1 50ms and sda 10ms of I/O in 1000ms; partitions and loop devices are left out.
    {_first, readings} = second([{"disk", []}])
    assert_in_delta readings["disk"], 3.0, 1.0e-9

    assert {_first, %{"disk" => 10.0}} = second([{"disk", ["loop0"]}])
  end

  test "net is received plus sent bytes per second, without loopback and virtual interfaces (C186)" do
    {_first, readings} = second([{"net", []}])
    assert readings["net"] == 4000.0

    assert {_first, %{"net" => 2_000_000.0}} = second([{"net", ["lo"]}])
    assert {_first, %{"net" => 1000.0}} = second([{"net", ["docker0"]}])
  end

  test "a counter that went back gives no value for that device, once" do
    metrics = metrics([{"net", ["eth0"]}])
    {_first, previous} = Machine.readings(metrics, texts(5), %{}, 1000)
    assert {[], previous} = Machine.readings(metrics, texts(1), previous, 2000)
    assert {[{"net", 4000.0}], _previous} = Machine.readings(metrics, texts(2), previous, 3000)
  end

  test "a file that cannot be read gives no value" do
    assert {[], _previous} = Machine.readings(metrics([{"mem", []}]), %{}, %{}, 1000)
  end

  test "this machine is read from /proc" do
    metrics = metrics([{"cpu", []}, {"mem", []}, {"net", ["lo"]}])
    {_first, previous} = Machine.sample(metrics, %{}, 0)
    {readings, _previous} = Machine.sample(metrics, previous, 100)
    readings = Map.new(readings)

    assert readings["mem"] > 0 and readings["mem"] <= 100
    assert readings["net"] >= 0
  end
end
