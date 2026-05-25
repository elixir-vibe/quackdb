defmodule QuackDB.DBConnection.QueryTest do
  use ExUnit.Case, async: true

  import QuackDB.TestTransports

  test "prepare_execute returns query metadata and result" do
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])
    connection = start_supervised!({QuackDB, transport: transport(prepare: [chunk])})

    assert {:ok, %QuackDB.Query{} = query, %QuackDB.Result{} = result} =
             QuackDB.prepare_execute(connection, "SELECT 1 AS n")

    assert query.columns == ["n"]
    assert query.result_uuid == 42
    assert result.rows == [[1]]
    assert result.command == :select
    assert result.connection_id == "conn-1"
    assert result.messages == []
  end

  test "ping returns ok when the connection can query" do
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])
    connection = start_supervised!({QuackDB, transport: transport(prepare: [chunk])})

    assert :ok = QuackDB.ping(connection)
  end

  test "ping returns query errors" do
    connection = start_supervised!({QuackDB, transport: transport_error("ping failed")})

    assert {:error, %QuackDB.Error{message: "ping failed", query: "SELECT 1"}} =
             QuackDB.ping(connection)
  end

  test "query supports decode_mapper like Postgrex" do
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1, 2])
    connection = start_supervised!({QuackDB, transport: transport(prepare: [chunk])})

    assert {:ok, %QuackDB.Result{rows: [%{n: 1}, %{n: 2}]}} =
             QuackDB.query(connection, "SELECT n", [], decode_mapper: fn [n] -> %{n: n} end)
  end

  test "formats parameters as SQL literals before sending Quack prepare requests" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    connection =
      start_supervised!({QuackDB, transport: transport(parent: parent, prepare: [chunk])})

    assert {:ok, %QuackDB.Result{rows: [[1]]}} =
             QuackDB.query(connection, "SELECT ? AS n", ["Robert'); DROP TABLE users;--"])

    assert_received {:statement, "SELECT 'Robert''); DROP TABLE users;--' AS n"}
  end
end
