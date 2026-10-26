defmodule QuackDB.InsertRowsTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.Message.SendDataRequest
  alias QuackDB.TestTransports

  defp start_conn!(options \\ []) do
    transport = TestTransports.append_transport(self(), options)

    {:ok, conn} =
      QuackDB.start_link(uri: "http://localhost:9494", token: "secret", transport: transport)

    conn
  end

  test "insert_rows streams row data into a client-data INSERT" do
    conn = start_conn!()

    assert {:ok, result} =
             QuackDB.insert_rows(conn, "events", [
               [id: 1, name: "one", active: true],
               [id: 2, name: "two", active: false]
             ])

    assert result.command == :insert
    assert result.num_rows == 2
    assert result.metadata.duckdb_columns == ["Count"]

    assert_receive {:statement, statement}

    assert statement ==
             ~s|INSERT INTO "events" ("id", "name", "active") SELECT * FROM | <>
               ~s|scan_data_from_quack_client('#{stream_id(statement)}', | <>
               ~s|NULL::STRUCT("id" INTEGER, "name" VARCHAR, "active" BOOLEAN))|

    assert_receive {:send_data, %SendDataRequest{batch_index: 1, chunks: [chunk]}}
    assert chunk.row_count == 2
    assert Enum.map(chunk.types, & &1.name) == [:integer, :varchar, :boolean]

    assert_receive {:send_data, %SendDataRequest{chunks: [], total_batches: 1}}
  end

  test "insert_rows qualifies the table with :schema" do
    conn = start_conn!()

    assert {:ok, _result} = QuackDB.insert_rows(conn, "events", [[id: 1]], schema: "analytics")

    assert_receive {:statement, ~s|INSERT INTO "analytics"."events" ("id") SELECT| <> _rest}
  end

  test "insert_rows sends one numbered batch per batch_size" do
    conn = start_conn!()

    assert {:ok, result} =
             QuackDB.insert_rows(
               conn,
               "events",
               [[id: 1, name: "one"], [id: 2, name: "two"], [id: 3, name: "three"]],
               batch_size: 2
             )

    assert result.num_rows == 3
    assert_receive {:send_data, %SendDataRequest{batch_index: 1, chunks: [%{row_count: 2}]}}
    assert_receive {:send_data, %SendDataRequest{batch_index: 2, chunks: [%{row_count: 1}]}}
    assert_receive {:send_data, %SendDataRequest{chunks: [], total_batches: 2}}
  end

  test "insert_rows splits batches into chunks of at most 2048 rows" do
    conn = start_conn!()
    rows = for id <- 1..5000, do: [id: id]

    assert {:ok, %QuackDB.Result{num_rows: 5000}} = QuackDB.insert_rows(conn, "events", rows)

    assert_receive {:send_data, %SendDataRequest{batch_index: 1, chunks: chunks}}
    assert Enum.map(chunks, & &1.row_count) == [2048, 2048, 904]
  end

  test "insert_rows batches with types inferred from the full row set" do
    conn = start_conn!()

    assert {:ok, %QuackDB.Result{num_rows: 2}} =
             QuackDB.insert_rows(
               conn,
               "events",
               [[id: 1, name: nil], [id: 2, name: "two"]],
               batch_size: 1
             )

    assert_receive {:send_data, %SendDataRequest{batch_index: 1, chunks: [first_chunk]}}
    assert_receive {:send_data, %SendDataRequest{batch_index: 2, chunks: [second_chunk]}}
    assert Enum.map(first_chunk.types, & &1.name) == [:integer, :varchar]
    assert Enum.map(second_chunk.types, & &1.name) == [:integer, :varchar]
  end

  test "insert_rows renders ON CONFLICT and RETURNING" do
    {:ok, returned} = DataChunk.from_rows([[id: 2, name: "two"]])

    conn =
      start_conn!(
        returning_rows: DataChunk.rows(returned) |> Enum.map(&Enum.zip([:id, :name], &1))
      )

    assert {:ok, result} =
             QuackDB.insert_rows(conn, "events", [[id: 1, name: "one"], [id: 2, name: "two"]],
               on_conflict: {:nothing, [:id]},
               returning: [:id, :name]
             )

    assert result.columns == ["id", "name"]
    assert result.rows == [[2, "two"]]
    assert result.num_rows == 1

    assert_receive {:statement, statement}
    assert statement =~ ~s|)) ON CONFLICT ("id") DO NOTHING RETURNING "id", "name"|
  end

  test "insert_rows sends VARIANT and JSON columns as JSON text" do
    conn = start_conn!()

    assert {:ok, _result} =
             QuackDB.insert_rows(
               conn,
               "events",
               [[payload: %{kind: "duck"}, raw: ~s({"a": 1})], [payload: "duck", raw: nil]],
               columns: [payload: :variant, raw: :json]
             )

    assert_receive {:statement, statement}
    assert statement =~ ~s|NULL::STRUCT("payload" JSON, "raw" JSON)|
    assert_receive {:send_data, %SendDataRequest{chunks: [chunk]}}
    assert DataChunk.rows(chunk) == [[~s({"kind":"duck"}), ~s({"a": 1})], [~s("duck"), nil]]
  end

  test "insert_rows rejects invalid batch sizes" do
    conn = start_conn!()

    assert {:error, %QuackDB.Error{code: :invalid_batch_size}} =
             QuackDB.insert_rows(conn, "events", [[id: 1]], batch_size: 0)

    refute_receive {:statement, _statement}
  end

  test "insert_rows accepts explicit columns for empty batches" do
    conn = start_conn!()

    assert {:ok, result} =
             QuackDB.insert_rows(conn, "events", [], columns: [id: :integer, name: :varchar])

    assert result.num_rows == 0
    assert_receive {:statement, statement}
    assert statement =~ ~s|NULL::STRUCT("id" INTEGER, "name" VARCHAR)|
    assert_receive {:send_data, %SendDataRequest{chunks: [], total_batches: 0}}
    refute_receive {:send_data, %SendDataRequest{batch_index: 1}}
  end

  defp stream_id(statement) do
    [_, stream_id] = Regex.run(~r/scan_data_from_quack_client\('([0-9a-f]+)'/, statement)
    stream_id
  end
end
