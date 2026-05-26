defmodule QuackDB.Transport.MintTest do
  use ExUnit.Case, async: false

  test "closes timed out connections before reuse" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    parent = self()
    server = spawn_link(fn -> serve_timeout_then_success(socket, parent) end)
    uri = URI.parse("http://localhost:#{port}")

    on_exit(fn ->
      :gen_tcp.close(socket)
      Process.exit(server, :kill)
    end)

    {:ok, transport} = QuackDB.Transport.Mint.start_link(uri)

    assert {:error, %QuackDB.Error{code: :transport_error}} =
             QuackDB.Transport.Mint.post(transport, uri, "", timeout: 20)

    assert_receive :first_client_closed, 1_000
    assert {:ok, "ok"} = QuackDB.Transport.Mint.post(transport, uri, "", timeout: 1_000)
  end

  test "ignores late TCP close messages" do
    uri = URI.parse("http://localhost:9494")
    {:ok, transport} = QuackDB.Transport.Mint.start_link(uri)

    send(transport, {:tcp_closed, Port.open({:spawn, "cat"}, [])})

    assert Process.alive?(transport)
  end

  test "reopens a closed HTTP connection" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    server = spawn_link(fn -> serve(socket, ["one", "two"]) end)
    uri = URI.parse("http://localhost:#{port}")

    on_exit(fn ->
      :gen_tcp.close(socket)
      Process.exit(server, :kill)
    end)

    {:ok, transport} = QuackDB.Transport.Mint.start_link(uri)

    assert {:ok, "one"} = QuackDB.Transport.Mint.post(transport, uri, "", timeout: 1_000)
    assert {:ok, "two"} = QuackDB.Transport.Mint.post(transport, uri, "", timeout: 1_000)
  end

  defp serve_timeout_then_success(socket, parent) do
    {:ok, first} = :gen_tcp.accept(socket)
    {:ok, _request} = :gen_tcp.recv(first, 0, 1_000)
    assert_tcp_closed(first)
    send(parent, :first_client_closed)

    {:ok, second} = :gen_tcp.accept(socket)
    {:ok, _request} = :gen_tcp.recv(second, 0, 1_000)

    :ok =
      :gen_tcp.send(second, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")

    :gen_tcp.close(second)
  end

  defp assert_tcp_closed(socket) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:error, :closed} -> :ok
      other -> flunk("expected client to close timed out socket, got: #{inspect(other)}")
    end
  end

  defp serve(_socket, []), do: :ok

  defp serve(socket, [body | rest]) do
    {:ok, client} = :gen_tcp.accept(socket)
    {:ok, _request} = :gen_tcp.recv(client, 0, 1_000)

    response = [
      "HTTP/1.1 200 OK\r\ncontent-length: ",
      Integer.to_string(byte_size(body)),
      "\r\nconnection: close\r\n\r\n",
      body
    ]

    :ok = :gen_tcp.send(client, response)
    :gen_tcp.close(client)
    serve(socket, rest)
  end
end
