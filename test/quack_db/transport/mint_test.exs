defmodule QuackDB.Transport.MintTest do
  use ExUnit.Case, async: false

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
