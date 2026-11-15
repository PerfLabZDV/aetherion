defmodule Aetherion.RequestsFile do
  @moduledoc """
  Writes the requests file (C120) during a Test, so a long run does not hold every
  request attempt in memory.

  Every 250ms the attempts that started more than a window ago go out, in time
  order, and the rest of a Test's attempts when it ends. The window is the longest a
  request can take with its retries, plus two seconds, plus thinkTime, since the last
  attempt of a request waits until the user's next request or the end of its
  iteration (C125). An attempt that becomes final later than that, after a sleep in
  Actions, is written when it arrives, a little out of order. On workers the main
  server writes the file, from the attempts the workers send.
  """

  alias Aetherion.{Recorder, Report}

  @every 250

  @doc "Starts writing the attempts `recorder` keeps; nothing to do without a requests file."
  def start(nil, _recorder, _window_ms, _run), do: nil

  def start(output, recorder, window_ms, run) do
    pid = spawn(fn -> loop(output, recorder, window_ms, run) end)
    %{pid: pid, ref: Process.monitor(pid), output: output, recorder: recorder, run: run}
  end

  defp loop(output, recorder, window_ms, run) do
    receive do
      {:stop, from} -> send(from, {:stopped, self()})
    after
      @every ->
        Report.write_requests(output, Recorder.take_requests(recorder, Recorder.now() - window_ms), run)
        loop(output, recorder, window_ms, run)
    end
  end

  @doc "Stops the writing and writes what is left, in time order. A file that cannot be written raises."
  def stop(nil), do: :ok

  def stop(%{pid: pid, ref: ref} = writer) do
    send(pid, {:stop, self()})

    receive do
      {:stopped, ^pid} -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, :process, ^pid, {%File.Error{} = error, _stack}} -> raise error
      {:DOWN, ^ref, :process, ^pid, reason} -> exit(reason)
    end

    Report.write_requests(writer.output, Recorder.take_requests(writer.recorder, :infinity), writer.run)
  end
end
