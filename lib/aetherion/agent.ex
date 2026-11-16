defmodule Aetherion.Agent do
  @moduledoc """
  The monitoring agent: a node on a machine under test that measures it for a
  main server (C185). It runs no virtual users.

  `aetherion agent --name sutServer1@192.168.178.91` starts one and waits, with
  the cookie of the main server. A target `sutServer1 { host =
  "192.168.178.91"; metrics = [cpu, mem, disk, net]; }` with `format =
  aetherion` in monitoring is measured by it.

  For each Test the main server starts a session here (`Aetherion.Monitor`). The
  session samples the target's metrics (`Aetherion.Machine`) at the interval of
  monitoring, times each sample on this node's clock, and keeps the samples until
  the main server takes them, so a late take loses nothing and does not move a
  sample in time. A session whose main server goes away ends, with the samples it
  still held.
  """

  alias Aetherion.{Cluster, Machine, Recorder}

  @ready {__MODULE__, :ready}

  @doc "Starts the node `name` with `cookie` and serves main servers until the VM stops."
  def serve(name, cookie) do
    with :ok <- Cluster.start_node(name) do
      Node.set_cookie(String.to_atom(cookie))
      prepare()
      IO.puts("Aetherion agent #{Node.self()} is ready")
      Process.sleep(:infinity)
    end
  end

  @doc "Makes this node, already distributed, ready for sessions."
  def prepare do
    Application.load(:aetherion)
    :persistent_term.put(@ready, true)
    :ok
  end

  @doc false
  def ready?, do: :persistent_term.get(@ready, false)

  @doc false
  # Called by the main server. `owner` takes the samples; `metrics` are
  # `%{name: metric, devices: devices}`.
  def start_session(owner, metrics, interval_ms),
    do: spawn(fn -> session(owner, metrics, interval_ms) end)

  defp session(owner, metrics, interval_ms) do
    send(self(), :sample)

    loop(%{
      ref: Process.monitor(owner),
      metrics: metrics,
      interval_ms: interval_ms,
      next: Recorder.now(),
      previous: %{},
      # Newest first.
      samples: []
    })
  end

  defp loop(%{ref: ref} = state) do
    receive do
      :sample ->
        loop(sample(state))

      {:aetherion_take, from, tag} ->
        send(from, {tag, Enum.reverse(state.samples)})
        loop(%{state | samples: []})

      :stop ->
        :ok

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    end
  end

  # Once per interval on a fixed schedule; one that falls behind samples at once.
  defp sample(state) do
    at = Recorder.now()
    {readings, previous} = Machine.sample(state.metrics, state.previous, at)
    wall = DateTime.to_iso8601(DateTime.utc_now())

    samples =
      Enum.reduce(readings, state.samples, fn {metric, value}, acc -> [{metric, value, at, wall} | acc] end)

    next = max(state.next + state.interval_ms, at)
    Process.send_after(self(), :sample, max(trunc(next - Recorder.now()), 0))
    %{state | previous: previous, samples: samples, next: next}
  end
end
