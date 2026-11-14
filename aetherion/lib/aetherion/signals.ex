defmodule Aetherion.Signals do
  @moduledoc """
  Turns SIGTERM into a message to the run, so that Cleanup still runs (C155).

  The Erlang VM does not let a program catch SIGINT. `bin/perflang` turns Ctrl+C
  into SIGTERM, so a terminal gets the same behaviour.
  """

  @behaviour :gen_event

  def install(pid) do
    :os.set_signal(:sigterm, :handle)
    :gen_event.swap_handler(:erl_signal_server, {:erl_signal_handler, []}, {__MODULE__, pid})
    :ok
  end

  @impl true
  def init({pid, _old}), do: {:ok, pid}

  @impl true
  def handle_event(:sigterm, pid) do
    send(pid, :perflang_interrupt)
    {:ok, pid}
  end

  def handle_event(_signal, pid), do: {:ok, pid}

  @impl true
  def handle_call(_request, pid), do: {:ok, :ok, pid}

  @impl true
  def handle_info(_message, pid), do: {:ok, pid}
end
