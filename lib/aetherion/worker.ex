defmodule Aetherion.Worker do
  @moduledoc """
  A worker: a node that runs virtual users for a main server (`Aetherion.Cluster`).

  `aetherion worker --name worker1@10.0.0.11` starts one and waits. For each Test,
  the main server starts a session here. The session runs its share of the users,
  and its part of a stage with a count, with the same code as a run on one machine
  (`Aetherion.Load`). It records into a recorder of its own, on the main server's
  window, and every 50ms sends the requests that count, its request attempts as
  they become final, its samples, and how far its part of a count stage is. When the main server stops it, the session stops its users,
  waits for their last requests, sends the rest and ends. Every time it sends is
  on the main server's clock. A session whose main server goes away stops its
  users at once.
  """

  alias Aetherion.{Cluster, Load, Monitor, Recorder}

  @forward_ms 50
  @ready {__MODULE__, :ready}

  @doc "Starts the node `name` with `cookie` and serves main servers until the VM stops."
  def serve(name, cookie) do
    with :ok <- Cluster.start_node(name) do
      Node.set_cookie(String.to_atom(cookie))
      prepare()
      IO.puts("Aetherion worker #{Node.self()} is ready")
      Process.sleep(:infinity)
    end
  end

  @doc "Makes this node, already distributed, ready for sessions."
  def prepare do
    Application.load(:aetherion)
    {:ok, _started} = Application.ensure_all_started(:ssl)
    :persistent_term.put(@ready, true)
    :ok
  end

  @doc false
  def ready?, do: :persistent_term.get(@ready, false)

  @doc false
  # Called by the main server, with job.offset_ms, how far its clock is ahead of this one.
  def start_session(controller, job), do: spawn(fn -> session(controller, job) end)

  defp session(controller, job) do
    recorder = Recorder.new(outbox: true, requests: job.requests)
    Recorder.join_window(recorder, job.marks, job.offset_ms)

    # The lists of Setup, copied into a table here, so users can read them and add to them.
    cells = :ets.new(:cells, [:ordered_set, :public])
    :ets.insert(cells, job.cells)
    vars = :ets.new(:vars, [:set, :public])

    ctx = job.ctx
    main_cells = job.cells_table

    scope =
      Map.new(ctx.test.setup_scope, fn
        {name, {:cell, ^main_cells, id}} -> {name, {:cell, cells, id}}
        pair -> pair
      end)

    test = %{ctx.test | recorder: recorder, cells: cells, vars: vars, setup_scope: scope}

    state = %{
      controller: controller,
      ref: Process.monitor(controller),
      users: Load.users(%{ctx | test: test}, job.first, job.step),
      recorder: recorder,
      cells: cells,
      vars: vars,
      copied: MapSet.new(job.cells, &elem(&1, 0)),
      offset: job.offset_ms,
      # The main server's number of the open count stage, and the last progress sent.
      stage: nil,
      sent: nil,
      # This worker is a load generator (C183): its samples wait here for the next report.
      name: Node.self() |> Atom.to_string() |> String.split("@") |> hd(),
      sampler: start_sampler(self(), ctx.rt.monitoring.interval_ms),
      samples: []
    }

    Process.send_after(self(), :forward, @forward_ms)
    loop(state)
  end

  defp loop(%{ref: ref} = state) do
    receive do
      {:users, target} ->
        loop(%{state | users: Load.resize(state.users, target)})

      {:count, stage, users, part, per_user} ->
        loop(%{state | users: Load.open(state.users, users, part, per_user), stage: stage})

      :free ->
        loop(%{state | users: Load.free(state.users), stage: nil})

      {:sample, readings, at, wall} ->
        samples = for {metric, value} <- readings, do: {state.name, metric, value, at + state.offset, wall}
        loop(%{state | samples: state.samples ++ samples})

      :forward ->
        state = forward(state)
        Process.send_after(self(), :forward, @forward_ms)
        loop(state)

      :stop ->
        finish(state)

      :abort ->
        abort(state)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        abort(state)

      {:DOWN, _ref, :process, pid, reason} ->
        loop(%{state | users: Load.user_down(state.users, pid, reason)})
    end
  end

  # Sends only when there is something new: requests, request attempts for the
  # requests file, samples, or progress in a count stage.
  defp forward(state) do
    {rows, records} = taken(state)
    progress = if state.stage, do: Map.put(Load.progress(state.users), :stage, state.stage)

    if rows != [] or records != [] or state.samples != [] or progress != state.sent do
      report = Map.merge(progress || %{stage: nil}, %{rows: rows, records: records, samples: state.samples})
      send(state.controller, {:aetherion_progress, self(), report})
    end

    %{state | sent: progress, samples: []}
  end

  # The requests that count, and the final request attempts on the main server's clock.
  defp taken(state) do
    records =
      for record <- Recorder.take_requests(state.recorder, :infinity),
          do: %{record | at: record.at + state.offset}

    {Recorder.take_counted(state.recorder), records}
  end

  # cpu and mem of this machine at the monitoring interval (C158, C183).
  defp start_sampler(session, interval_ms), do: spawn_link(fn -> sample(session, interval_ms, nil) end)

  defp sample(session, interval_ms, previous) do
    {readings, previous} = Monitor.sample_machine(previous)

    if readings != [],
      do: send(session, {:sample, readings, Recorder.now(), DateTime.to_iso8601(DateTime.utc_now())})

    Process.sleep(interval_ms)
    sample(session, interval_ms, previous)
  end

  defp finish(state) do
    Load.stop_users(state.users)
    stop_sampler(state)
    state = drain_samples(state)

    {rows, records} = taken(state)

    result = %{
      rows: rows,
      records: records,
      samples: state.samples,
      recorder: Recorder.export(state.recorder),
      vars: for({name, value, at} <- :ets.tab2list(state.vars), do: {name, value, at + state.offset}),
      cell_adds: for({key, _value} = row <- :ets.tab2list(state.cells), key not in state.copied, do: row)
    }

    send(state.controller, {:aetherion_done, self(), result})
  end

  defp stop_sampler(%{sampler: sampler}) do
    Process.unlink(sampler)
    Process.exit(sampler, :kill)
  end

  defp drain_samples(state) do
    receive do
      {:sample, readings, at, wall} ->
        samples = for {metric, value} <- readings, do: {state.name, metric, value, at + state.offset, wall}
        drain_samples(%{state | samples: state.samples ++ samples})
    after
      0 -> state
    end
  end

  defp abort(state) do
    stop_sampler(state)
    Enum.each(state.users.users ++ state.users.stopping, &Process.exit(&1, :kill))
  end
end
