defmodule Aetherion.TestServer do
  @moduledoc "A small HTTP/1.1 server on a real socket, with keep-alive, for the engine tests."

  def start(routes) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, backlog: 512])
    {:ok, port} = :inet.port(listen)
    log = :ets.new(:http_log, [:public, :ordered_set])
    connections = :counters.new(1, [])
    pid = spawn(fn -> accept(listen, routes, log, connections) end)

    %{
      port: port,
      url: "http://127.0.0.1:#{port}",
      log: log,
      pid: pid,
      listen: listen,
      connections: connections
    }
  end

  def stop(server) do
    Process.exit(server.pid, :kill)
    :gen_tcp.close(server.listen)
  end

  def requests(server), do: for({_key, request} <- :ets.tab2list(server.log), do: request)
  def connections(server), do: :counters.get(server.connections, 1)

  defp accept(listen, routes, log, connections) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        :counters.add(connections, 1, 1)
        pid = spawn(fn -> receive(do: (:go -> serve(socket, routes, log, ""))) end)
        :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept(listen, routes, log, connections)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, routes, log, buffer) do
    case read(socket, buffer) do
      {:ok, request, rest} ->
        :ets.insert(log, {{System.monotonic_time(), :erlang.unique_integer([:monotonic])}, request})

        case respond(routes, request) do
          :close ->
            :gen_tcp.close(socket)

          {status, headers, body} ->
            lines = Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

            :gen_tcp.send(socket, [
              "HTTP/1.1 #{status} X\r\ncontent-length: #{byte_size(body)}\r\n",
              lines,
              "\r\n",
              if(request.method == "HEAD", do: "", else: body)
            ])

            serve(socket, routes, log, rest)
        end

      :closed ->
        :ok
    end
  end

  defp respond(routes, request) do
    case routes.(request) do
      {:sleep, ms, reply} ->
        Process.sleep(ms)
        normalize(reply)

      reply ->
        normalize(reply)
    end
  end

  defp normalize(:close), do: :close
  defp normalize(status) when is_integer(status), do: {status, [], ""}
  defp normalize({status, body}) when is_binary(body), do: {status, [], body}
  defp normalize({status, body}), do: {status, [{"content-type", "application/json"}], JSON.encode!(body)}

  defp read(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] -> read_body(socket, head, rest)
      [_] -> more(socket, buffer, &read(socket, &1))
    end
  end

  defp read_body(socket, head, rest) do
    [start | lines] = String.split(head, "\r\n")
    [method, target, _version] = String.split(start, " ")

    headers =
      Map.new(lines, fn line ->
        [name, value] = String.split(line, ": ", parts: 2)
        {String.downcase(name), value}
      end)

    length = String.to_integer(Map.get(headers, "content-length", "0"))

    if byte_size(rest) >= length do
      <<body::binary-size(length), remaining::binary>> = rest
      [path | query] = String.split(target, "?", parts: 2)

      request = %{
        method: method,
        target: target,
        path: path,
        query: List.first(query),
        headers: headers,
        body: body
      }

      {:ok, request, remaining}
    else
      more(socket, rest, &read_body(socket, head, &1))
    end
  end

  defp more(socket, buffer, next) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} -> next.(buffer <> data)
      {:error, _reason} -> :closed
    end
  end
end

defmodule Aetherion.TestBroker do
  @moduledoc "Just enough of an MQTT 3.1.1 broker for the engine tests: CONNECT, SUBSCRIBE and publishing to clients."

  def start do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    clients = :ets.new(:mqtt_clients, [:public, :bag])
    pid = spawn(fn -> accept(listen, clients) end)
    %{port: port, url: "mqtt://127.0.0.1:#{port}", pid: pid, listen: listen, clients: clients}
  end

  def stop(broker) do
    Process.exit(broker.pid, :kill)
    :gen_tcp.close(broker.listen)
  end

  def subscribed?(broker, topic), do: :ets.lookup(broker.clients, topic) != []

  def publish(broker, topic, payload, opts \\ []) do
    flags = if opts[:retain], do: 1, else: 0
    body = <<byte_size(topic)::16, topic::binary, payload::binary>>

    for {^topic, socket} <- :ets.lookup(broker.clients, topic) do
      :gen_tcp.send(socket, <<3::4, flags::4, remaining(byte_size(body))::binary, body::binary>>)
    end
  end

  defp remaining(size) when size < 128, do: <<size>>
  defp remaining(size), do: <<rem(size, 128) + 128, remaining(div(size, 128))::binary>>

  defp accept(listen, clients) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> receive(do: (:go -> loop(socket, clients))) end)
        :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept(listen, clients)

      {:error, _reason} ->
        :ok
    end
  end

  defp loop(socket, clients) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, <<1::4, _flags::4, _rest::binary>>} ->
        :gen_tcp.send(socket, <<0x20, 2, 0, 0>>)
        loop(socket, clients)

      {:ok,
       <<8::4, _flags::4, _size, id::16, topic_size::16, topic::binary-size(topic_size), _qos, _rest::binary>>} ->
        :ets.insert(clients, {topic, socket})
        :gen_tcp.send(socket, <<0x90, 3, id::16, 1>>)
        loop(socket, clients)

      {:ok, <<12::4, _flags::4, _rest::binary>>} ->
        :gen_tcp.send(socket, <<0xD0, 0>>)
        loop(socket, clients)

      {:ok, _other} ->
        loop(socket, clients)

      {:error, _reason} ->
        :ok
    end
  end
end
