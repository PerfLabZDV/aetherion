defmodule Aetherion.Load do
  @moduledoc """
  Runs Actions under the stages (C19-C30, C101-C103, C127, C128, C169).

  Each virtual user is a process that repeats Actions. A stage with a count
  starts exactly that many iterations in total: users claim them from a shared
  budget, and the stage ends when every claimed iteration has finished (C103).
  With a count per user, each user also keeps to its own share (C175). Between
  a count stage and the next stage the budget stays closed, so no iteration
  runs that no stage counts. When the run ends or a ramp takes a user away, the
  user finishes its current request and starts no other, and the run waits
  for it, so that request is recorded and counts.

  stopIf is checked once a second (C58). Returns `:finished`, `{:stopped, source}`
  or `:interrupted`.
  """

  alias PerfLang.AST
  alias Aetherion.{Http, Interpreter, Recorder, Source, Values}

  @tick 10

  # The shared counters of the stages. counting is 0 in a time stage, where
  # users run freely, and 1 in a count stage, where they claim from budget.
  # done counts the claimed iterations that have finished. stage numbers the
  # count stages, so a user can tell which one its own count belongs to, and
  # per_user is the count per user of a stage with iter/vu, 0 otherwise.
  @budget 1
  @counting 2
  @done 3
  @stage 4
  @per_user 5

  # The count stage and the iterations this user has claimed in it.
  @claimed :perflang_claimed

  def run(ctx) do
    budget = :atomics.new(5, signed: true)
    # users are the users of the current stage, stopping the users a stage
    # took away that are still finishing their request.
    state = %{ctx: ctx, users: [], stopping: [], next: 1, budget: budget}
    watcher = start_watcher(ctx)

    result =
      ctx.test.load.stages
      |> Enum.reduce_while({0, state}, fn stage, {previous, state} ->
        case run_stage(stage, previous, state) do
          {:cont, state} -> {:cont, {count(stage), state}}
          {:halt, reason, state} -> {:halt, {reason, state}}
        end
      end)

    stop_watcher(watcher)

    case result do
      {reason, state} when not is_integer(reason) ->
        stop_all(state)
        reason

      {_count, state} ->
        stop_all(state)
        :finished
    end
  end

  defp count(%{users: %AST.UsersLiteral{value: value}}), do: value

  # ---------- Stages ----------

  defp run_stage(%AST.NowStage{} = stage, _previous, state), do: {:cont, set_users(state, count(stage))}

  defp run_stage(%AST.HoldStage{duration: %AST.TimeLiteral{} = duration} = stage, _previous, state) do
    run_freely(state)
    state = set_users(state, count(stage))
    wait_until(state, Recorder.now() + Values.milliseconds(duration))
  end

  # Every user in the stage runs exactly per_user iterations (C175).
  defp run_stage(
         %AST.HoldStage{duration: %AST.IterationsLiteral{value: per_user, per_user: true}} = stage,
         _previous,
         state
       ) do
    users = count(stage)
    total = users * per_user
    state = open_budget(state, users, total, per_user)
    wait_for_budget(state, total, fn state, _progress -> state end)
  end

  defp run_stage(%AST.HoldStage{duration: %AST.IterationsLiteral{value: total}} = stage, _previous, state) do
    state = open_budget(state, count(stage), total, 0)
    wait_for_budget(state, total, fn state, _progress -> state end)
  end

  defp run_stage(%AST.RampStage{duration: %AST.TimeLiteral{} = duration} = stage, previous, state) do
    run_freely(state)
    length = Values.milliseconds(duration)
    start = Recorder.now()
    ramp_time(stage, previous, state, start, length)
  end

  defp run_stage(%AST.RampStage{duration: %AST.IterationsLiteral{value: total}} = stage, previous, state) do
    target = count(stage)

    # A ramp by iterations needs a user to start with.
    state = open_budget(state, max(previous, 1), total, 0)

    wait_for_budget(state, total, fn state, progress ->
      set_users(state, step(stage, previous, target, progress, state))
    end)
  end

  defp ramp_time(stage, previous, state, start, length) do
    progress = if length > 0, do: min((Recorder.now() - start) / length, 1.0), else: 1.0
    state = set_users(state, step(stage, previous, count(stage), progress, state))

    if progress >= 1 do
      {:cont, state}
    else
      case tick(state) do
        {:cont, state} -> ramp_time(stage, previous, state, start, length)
        halt -> halt
      end
    end
  end

  defp step(stage, previous, target, progress, state) do
    round(previous + (target - previous) * shape(stage.curve, progress, state))
  end

  # A curve gives a shape from 0 to 1 (C30). The built-ins are scaled to it.
  defp shape(nil, t, _state), do: t

  defp shape(%AST.CurveRef{name: name, args: args}, t, %{ctx: ctx}) do
    args = Enum.map(args || [], &Values.literal/1)
    curve_ctx = %{ctx | phase: :curve}

    value =
      case ctx.test.load.curves[name] do
        nil -> builtin_shape(name, t, args)
        definition -> Interpreter.curve(definition, [t | args], curve_ctx)
      end

    value |> max(0.0) |> min(1.0)
  end

  defp builtin_shape("linear", t, _args), do: t
  defp builtin_shape("abs", t, _args), do: t
  defp builtin_shape("sqrt", t, _args), do: :math.sqrt(t)
  defp builtin_shape("exp", t, _args), do: (:math.exp(t) - 1) / (:math.exp(1) - 1)
  defp builtin_shape("log", t, _args), do: :math.log(1 + t * (:math.exp(1) - 1))
  defp builtin_shape("sin", t, _args), do: :math.sin(t * :math.pi() / 2)
  defp builtin_shape("cos", t, _args), do: 1 - :math.cos(t * :math.pi() / 2)
  defp builtin_shape("min", t, [limit]), do: min(t, limit)
  defp builtin_shape("max", t, [limit]), do: max(t, limit)

  defp wait_until(state, deadline) do
    if Recorder.now() >= deadline do
      {:cont, state}
    else
      case tick(state) do
        {:cont, state} -> wait_until(state, deadline)
        halt -> halt
      end
    end
  end

  # The stage ends when every iteration it counts has finished. The budget
  # stays closed afterwards, so users wait for the next stage (C103).
  defp wait_for_budget(state, total, on_progress) do
    if :atomics.get(state.budget, @done) >= total do
      {:cont, state}
    else
      remaining = max(:atomics.get(state.budget, @budget), 0)
      state = on_progress.(state, (total - remaining) / total)

      case tick(state) do
        {:cont, state} -> wait_for_budget(state, total, on_progress)
        halt -> halt
      end
    end
  end

  # Closes the budget before the user count changes, so a user that is told
  # to stop cannot claim from the new stage, then opens it. The stage number
  # changes before the budget opens, so a user that claims from it reads the
  # new number.
  defp open_budget(%{budget: budget} = state, users, total, per_user) do
    :atomics.put(budget, @budget, 0)
    :atomics.put(budget, @counting, 1)
    state = set_users(state, users)
    :atomics.put(budget, @done, 0)
    :atomics.put(budget, @per_user, per_user)
    :atomics.add(budget, @stage, 1)
    :atomics.put(budget, @budget, total)
    state
  end

  # A time stage: users run iterations without claiming them.
  defp run_freely(%{budget: budget}), do: :atomics.put(budget, @counting, 0)

  # ---------- The controller's clock ----------

  defp tick(state) do
    receive do
      :perflang_interrupt ->
        {:halt, :interrupted, state}

      {:perflang_stop_if, source} ->
        {:halt, {:stopped, source}, state}

      {:DOWN, _ref, :process, pid, reason} when reason in [:normal, :killed] ->
        {:cont, %{state | users: List.delete(state.users, pid), stopping: List.delete(state.stopping, pid)}}

      {:DOWN, _ref, :process, pid, reason} ->
        # The other users must not outlive the run.
        stop_all(%{state | users: List.delete(state.users, pid), stopping: List.delete(state.stopping, pid)})
        raise "a virtual user crashed: #{inspect(reason)}"
    after
      @tick -> {:cont, state}
    end
  end

  # stopIf has its own process: reading metrics must not delay the stages.
  defp start_watcher(%{test: %{load: %{stop_ifs: []}}}), do: nil

  defp start_watcher(ctx) do
    parent = self()
    ctx = %{ctx | phase: :stop_if}
    spawn(fn -> watch(ctx, parent) end)
  end

  defp watch(ctx, parent) do
    Process.sleep(1000)

    case Enum.find(ctx.test.load.stop_ifs, &Interpreter.condition(&1, ctx)) do
      nil -> watch(ctx, parent)
      condition -> send(parent, {:perflang_stop_if, Source.text(condition)})
    end
  end

  defp stop_watcher(nil), do: :ok
  defp stop_watcher(pid), do: Process.exit(pid, :kill)

  # ---------- Virtual users ----------

  defp set_users(state, target) do
    current = length(state.users)

    state =
      cond do
        target > current ->
          Enum.reduce(1..(target - current), state, fn _n, state -> start_user(state) end)

        target < current ->
          {stopping, kept} = Enum.split(state.users, current - target)
          Enum.each(stopping, &send(&1, Http.stop_message()))
          %{state | users: kept, stopping: stopping ++ state.stopping}

        true ->
          state
      end

    Recorder.users(state.ctx.test.recorder, target)
    state
  end

  defp start_user(state) do
    budget = state.budget
    ctx = %{state.ctx | vu: state.next}
    {pid, _ref} = spawn_monitor(fn -> user(ctx, budget) end)
    %{state | users: [pid | state.users], next: state.next + 1}
  end

  defp user(ctx, budget) do
    :rand.seed(:exsss, {ctx.rt.seed, ctx.test.index, ctx.vu})

    try do
      loop(ctx, budget, 1)
    catch
      {:perflang, :user_stopped} -> :ok
    end

    Recorder.flush()
    Http.close()
  end

  defp loop(ctx, budget, iteration) do
    Http.check_stop()

    case claim(budget) do
      false ->
        # No iterations left for this user in this stage: wait for the next one.
        if Http.sleep(5) == :stopped, do: Http.check_stop()
        loop(ctx, budget, iteration)

      claim ->
        # Told to stop while claiming: hand the iteration back for another user.
        try do
          Http.check_stop()
        catch
          stopped ->
            unclaim(claim, budget)
            throw(stopped)
        end

        try do
          iterate(%{ctx | iteration: iteration})
        after
          if claim == :counted, do: :atomics.add(budget, @done, 1)
        end

        loop(ctx, budget, iteration + 1)
    end
  end

  # In a time stage every iteration is free. A stage with a count starts
  # exactly that many iterations (C103), and with a count per user no user
  # runs more than its share (C175).
  defp claim(budget) do
    if :atomics.get(budget, @counting) == 0 do
      :free
    else
      stage = :atomics.get(budget, @stage)
      per_user = :atomics.get(budget, @per_user)

      cond do
        per_user > 0 and claimed(stage) >= per_user ->
          false

        take(budget) ->
          # The budget opens after the stage number changes, so read it again.
          stage = :atomics.get(budget, @stage)
          Process.put(@claimed, {stage, claimed(stage) + 1})
          :counted

        true ->
          false
      end
    end
  end

  # Takes one iteration from the budget. It never goes below 0, so an
  # iteration handed back is there for the next user.
  defp take(budget) do
    case :atomics.get(budget, @budget) do
      left when left <= 0 ->
        false

      left ->
        case :atomics.compare_exchange(budget, @budget, left, left - 1) do
          :ok -> true
          _changed -> take(budget)
        end
    end
  end

  defp claimed(stage) do
    case Process.get(@claimed) do
      {^stage, count} -> count
      _other -> 0
    end
  end

  defp unclaim(:free, _budget), do: :ok

  defp unclaim(:counted, budget) do
    {stage, count} = Process.get(@claimed)
    Process.put(@claimed, {stage, count - 1})
    :atomics.add(budget, @budget, 1)
  end

  defp iterate(ctx) do
    Interpreter.new_iteration()

    try do
      Interpreter.run(ctx.test.actions, [%{}, ctx.test.setup_scope], ctx)
    catch
      {:perflang, :end_iteration} -> :ok
    end

    Recorder.flush()
  end

  # Waits for the users of the last stage and for those a stage took away:
  # a user still in a request would record it after the run has ended.
  defp stop_all(state) do
    Enum.each(state.users, &send(&1, Http.stop_message()))
    load = state.ctx.test.load
    grace = (load.timeout_ms + load.retry.delay_ms) * load.retry.attempts + 2000
    await(state.users ++ state.stopping, Recorder.now() + grace)
  end

  defp await([], _deadline), do: :ok

  defp await(users, deadline) do
    receive do
      :perflang_interrupt ->
        await(users, deadline)

      {:DOWN, _ref, :process, pid, _reason} ->
        await(List.delete(users, pid), deadline)
    after
      max(trunc(deadline - Recorder.now()), 0) ->
        Enum.each(users, &Process.exit(&1, :kill))
    end
  end
end
