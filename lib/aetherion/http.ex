defmodule Aetherion.Http do
  @moduledoc """
  The HTTP client: one Mint connection per process and origin (C170).

  A virtual user keeps its connection alive and reconnects when the system under
  test closes it. Connecting counts in latency, and requestTimeout covers the
  whole request (C96). A 3xx is not followed. Retries run here (C38, C86), and so
  does thinkTime, which waits before the next request after a response (C16).
  """

  alias Aetherion.Recorder

  @connections {__MODULE__, :connections}
  @think {__MODULE__, :think_until}
  @stopped {__MODULE__, :stopped}

  @stop :perflang_stop

  @doc "The message that ends a virtual user, after its current request (C169)."
  def stop_message, do: @stop

  @doc "Ends the user here if it was told to stop. Called before every request."
  def check_stop do
    stopped? =
      Process.get(@stopped, false) or
        receive do
          @stop -> true
        after
          0 -> false
        end

    if stopped?, do: throw({:perflang, :user_stopped})
  end

  @doc "Sleeps, returning early with `:stopped` when the user is told to stop."
  def sleep(ms) when ms <= 0, do: :ok

  def sleep(ms) do
    receive do
      @stop ->
        Process.put(@stopped, true)
        :stopped
    after
      trunc(ms) -> :ok
    end
  end

  @doc "A call of a test. `request` holds target, method, url, path, headers and body. Returns a Response."
  def call(request, ctx) do
    if ctx.phase == :actions do
      check_stop()
      think()
    end

    response = attempts(request, ctx, 1)

    if ctx.phase == :actions do
      Process.put(@think, Recorder.now() + ctx.test.load.think_ms)
    end

    response
  end

  defp think do
    case Process.get(@think) do
      nil ->
        :ok

      until ->
        if sleep(until - Recorder.now()) == :stopped, do: check_stop()
    end
  end

  defp attempts(request, ctx, attempt) do
    retry = ctx.test.load.retry
    wall = DateTime.utc_now()
    at = Recorder.now()
    warmup? = ctx.phase == :actions and Recorder.warmup?(ctx.test.recorder)
    response = once(request, ctx.test.load.timeout_ms)
    latency = Recorder.now() - at
    response = %{response | latency: {:time, latency}}
    retry? = attempt < retry.attempts and retryable?(response)

    Recorder.attempt(
      ctx.test.recorder,
      %{
        at: at,
        time: DateTime.to_iso8601(wall),
        test: ctx.test.name,
        phase: phase_name(ctx.phase),
        virtualUser: ctx.vu,
        iteration: ctx.iteration,
        target: request.target,
        method: request.method,
        url: request.url,
        path: request.path,
        status: response.status,
        latency: latency,
        outcome: response.outcome,
        attempt: attempt,
        warmup: warmup?,
        last: true
      },
      not retry?
    )

    cond do
      not retry? -> response
      sleep(wait(retry, attempt)) == :stopped -> response
      true -> attempts(request, ctx, attempt + 1)
    end
  end

  defp phase_name(:setup), do: "Setup"
  defp phase_name(:actions), do: "Actions"
  defp phase_name(:verify), do: "Verify"
  defp phase_name(:cleanup), do: "Cleanup"

  defp retryable?(%{outcome: outcome}) when outcome in ["timeout", "connectionError"], do: true
  defp retryable?(%{status: status}), do: status >= 500

  defp wait(%{backoff: :fixed, delay_ms: delay}, _attempt), do: delay
  defp wait(%{backoff: :linear, delay_ms: delay}, attempt), do: delay * attempt
  defp wait(%{backoff: :exponential, delay_ms: delay}, attempt), do: delay * Integer.pow(2, attempt - 1)

  # ---------- One request ----------

  # A target with no baseUrl, reached through a Target value (C156).
  defp once(%{full_url: nil}, _timeout), do: failed("connectionError")

  defp once(request, timeout) do
    uri = URI.parse(request.full_url)
    scheme = String.to_existing_atom(uri.scheme)
    origin = {scheme, uri.host, uri.port}
    deadline = Recorder.now() + timeout
    send_request(request, origin, deadline, _retried = false)
  end

  defp send_request(request, origin, deadline, retried?) do
    {conn, reused?} = connection(origin)

    with {:ok, conn} <- ensure_open(conn, origin, deadline),
         {:ok, conn, ref} <- start(conn, request),
         {:ok, conn, result} <- receive_response(conn, ref, deadline, %{status: nil, headers: [], body: []}) do
      keep(origin, conn)
      response(request, result)
    else
      {:error, :timeout} ->
        forget(origin)
        failed("timeout")

      {:error, _reason} when reused? and not retried? ->
        # The system under test closed an idle connection: not a failed request.
        forget(origin)
        send_request(request, origin, deadline, true)

      {:error, _reason} ->
        forget(origin)
        failed("connectionError")
    end
  end

  defp connection(origin) do
    case Process.get(@connections, %{}) do
      %{^origin => conn} -> {conn, Mint.HTTP.open?(conn)}
      _ -> {nil, false}
    end
  end

  defp keep(origin, conn) do
    connections = Process.get(@connections, %{})

    if Mint.HTTP.open?(conn),
      do: Process.put(@connections, Map.put(connections, origin, conn)),
      else: Process.put(@connections, Map.delete(connections, origin))
  end

  defp forget(origin) do
    connections = Process.get(@connections, %{})

    case connections do
      %{^origin => conn} ->
        Mint.HTTP.close(conn)
        Process.put(@connections, Map.delete(connections, origin))

      _ ->
        :ok
    end
  end

  @doc "Closes the connections of this process."
  def close do
    for {_origin, conn} <- Process.delete(@connections) || %{}, do: Mint.HTTP.close(conn)
    :ok
  end

  defp ensure_open(conn, {scheme, host, port}, deadline) do
    if conn != nil and Mint.HTTP.open?(conn) do
      {:ok, conn}
    else
      timeout = max(trunc(deadline - Recorder.now()), 1)

      case Mint.HTTP.connect(scheme, host, port,
             mode: :passive,
             protocols: [:http1],
             transport_opts: [timeout: timeout]
           ) do
        {:ok, conn} -> {:ok, conn}
        {:error, %{reason: :timeout}} -> {:error, :timeout}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start(conn, %{method: method, target_path: path, headers: headers, body: body}) do
    case Mint.HTTP.request(conn, method, path, headers, body) do
      {:ok, conn, ref} -> {:ok, conn, ref}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp receive_response(conn, ref, deadline, acc) do
    remaining = trunc(deadline - Recorder.now())

    if remaining <= 0 do
      {:error, :timeout}
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, parts} ->
          case collect(parts, ref, acc) do
            {:done, result} -> {:ok, conn, result}
            {:more, acc} -> receive_response(conn, ref, deadline, acc)
          end

        {:error, _conn, %{reason: :timeout}, _parts} ->
          {:error, :timeout}

        {:error, conn, reason, parts} ->
          case collect(parts, ref, acc) do
            {:done, result} -> {:ok, conn, result}
            {:more, _acc} -> {:error, reason}
          end
      end
    end
  end

  defp collect([], _ref, acc), do: {:more, acc}
  defp collect([{:status, ref, status} | rest], ref, acc), do: collect(rest, ref, %{acc | status: status})
  defp collect([{:headers, ref, headers} | rest], ref, acc), do: collect(rest, ref, %{acc | headers: headers})
  defp collect([{:data, ref, data} | rest], ref, acc), do: collect(rest, ref, %{acc | body: [acc.body, data]})
  defp collect([{:done, ref} | _rest], ref, acc), do: {:done, acc}
  defp collect([_other | rest], ref, acc), do: collect(rest, ref, acc)

  defp response(_request, %{status: status, headers: headers, body: body}) do
    %{
      status: status,
      outcome: if(status < 400, do: "ok", else: "failed"),
      latency: {:time, 0},
      body: decode(IO.iodata_to_binary(body)),
      headers: Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
    }
  end

  defp failed(outcome), do: %{status: 0, outcome: outcome, latency: {:time, 0}, body: nil, headers: %{}}

  # JSON null when the body is not JSON (C110).
  defp decode(""), do: nil

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, value} -> value
      {:error, _reason} -> nil
    end
  end

  @doc "A plain GET for a monitoring agent, with no recording. Returns `{:ok, body}` or `:error`."
  def fetch(url, timeout) do
    uri = URI.parse(url)
    origin = {:agent, uri.host, uri.port}
    deadline = Recorder.now() + timeout
    conn_origin = {String.to_existing_atom(uri.scheme), uri.host, uri.port}
    {conn, _reused?} = connection(origin)

    with {:ok, conn} <- ensure_open(conn, conn_origin, deadline),
         {:ok, conn, ref} <-
           start(conn, %{method: "GET", target_path: uri.path || "/", headers: [], body: nil}),
         {:ok, conn, result} <- receive_response(conn, ref, deadline, %{status: nil, headers: [], body: []}),
         true <- result.status < 400 do
      keep(origin, conn)
      {:ok, IO.iodata_to_binary(result.body)}
    else
      _ ->
        forget(origin)
        :error
    end
  end
end
