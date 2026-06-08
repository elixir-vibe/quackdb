defmodule QuackDB.Integration.QueryTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "queries a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["n"], rows: [[1]], num_rows: 1}} =
             QuackDB.query(connection, "SELECT 1 AS n")
  end

  test "profiles a query with DuckDB explain analyze JSON" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Profile{} = profile} =
             QuackDB.Profile.analyze(
               connection,
               "SELECT i, i % 10 AS bucket FROM range(1000) t(i) WHERE i > 10 ORDER BY bucket LIMIT 5"
             )

    assert profile.latency > 0
    assert profile.cpu_time > 0
    assert profile.cumulative_rows_scanned == 1000
    assert [_ | _] = operators = QuackDB.Profile.flatten(profile)
    assert Enum.any?(operators, &(&1.name in ["RANGE", "SEQ_SCAN "]))

    report = QuackDB.Profile.report(profile, limit: 3)
    assert report =~ "DuckDB query profile"
    assert report =~ "Rows scanned:"
  end

  test "finds and allocates sequence values from a real Quack server" do
    connection = start_connection!()
    sequence = "quackdb_sequence_test_#{System.unique_integer([:positive])}"

    assert {:ok, _result} =
             QuackDB.query(connection, [
               "CREATE SEQUENCE ",
               QuackDB.Type.quote_identifier(sequence)
             ])

    table = "quackdb_sequence_table_#{System.unique_integer([:positive])}"

    assert {:ok, _result} =
             QuackDB.query(connection, [
               "CREATE TABLE ",
               QuackDB.Type.quote_identifier(table),
               " (id BIGINT DEFAULT nextval('",
               sequence,
               "'), name VARCHAR)"
             ])

    assert QuackDB.Sequence.for_column!(connection, table, :id) == sequence

    assert {:error, %QuackDB.Error{code: :sequence_not_found}} =
             QuackDB.Sequence.for_column(connection, table, :name)

    assert QuackDB.Sequence.next_values(connection, sequence, 3) == [1, 2, 3]
    assert QuackDB.Sequence.next_values(connection, sequence, 2) == [4, 5]
    assert QuackDB.Sequence.next_values(connection, sequence, 0) == []
  end

  test "decodes mixed scalar results from a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["ok", "name", "amount"]} = result} =
             QuackDB.query(
               connection,
               "SELECT true AS ok, 'duck' AS name, 12.5::DOUBLE AS amount"
             )

    assert result.rows == [[true, "duck", 12.5]]
  end

  test "decodes nulls, temporal values, and decimals from a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["n", "s", "d", "ts", "dec"]} = result} =
             QuackDB.query(
               connection,
               "SELECT NULL::INTEGER AS n, NULL::VARCHAR AS s, DATE '2024-01-02' AS d, TIMESTAMP '2024-01-02 03:04:05' AS ts, 12.34::DECIMAL(18,2) AS dec"
             )

    assert result.rows == [
             [nil, nil, ~D[2024-01-02], ~N[2024-01-02 03:04:05.000000], Decimal.new("12.34")]
           ]
  end

  test "fetches large result sets from a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{} = result} =
             QuackDB.query(connection, "SELECT i::INTEGER AS n FROM range(0, 50000) t(i)")

    assert result.metadata.needs_more_fetch == true
    assert result.num_rows == 50_000
    assert hd(result.rows) == [0]
    assert Enum.at(result.rows, -1) == [49_999]
  end

  test "decodes nested DuckDB types from a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["xs", "obj", "arr", "m", "nested"]} = result} =
             QuackDB.query(
               connection,
               "SELECT [1,2,3] AS xs, {'name': 'duck', 'count': 2} AS obj, array_value(1,2,3) AS arr, map(['a','b'], [1,2]) AS m, [{'a': 1}, {'a': 2}] AS nested"
             )

    assert result.rows == [
             [
               [1, 2, 3],
               %{"name" => "duck", "count" => 2},
               [1, 2, 3],
               %{"a" => 1, "b" => 2},
               [%{"a" => 1}, %{"a" => 2}]
             ]
           ]
  end

  test "normalizes command affected row counts from a real Quack server" do
    connection = start_connection!()
    table = "quackdb_command_#{System.unique_integer([:positive])}"

    assert {:ok, %QuackDB.Result{command: :create, columns: nil, rows: nil, num_rows: 0} = create} =
             QuackDB.query(
               connection,
               QuackDB.DDL.create_table(table, [id: :integer, name: :varchar], temporary: true)
             )

    assert create.metadata[:duckdb_columns] == ["Count"]
    assert create.metadata[:duckdb_rows] == []

    assert {:ok, %QuackDB.Result{command: :insert, columns: nil, rows: nil, num_rows: 2} = insert} =
             QuackDB.query(
               connection,
               QuackDB.DML.insert_into(table, [[id: 1, name: "duck"], [id: 2, name: "goose"]])
             )

    assert insert.metadata[:duckdb_rows] == [[2]]

    assert {:ok, %QuackDB.Result{command: :update, columns: nil, rows: nil, num_rows: 1} = update} =
             QuackDB.query(connection, "UPDATE #{table} SET name = 'mallard' WHERE id = 1")

    assert update.metadata[:duckdb_rows] == [[1]]

    assert {:ok, %QuackDB.Result{command: :delete, columns: nil, rows: nil, num_rows: 1} = delete} =
             QuackDB.query(connection, "DELETE FROM #{table} WHERE id = 2")

    assert delete.metadata[:duckdb_rows] == [[1]]

    assert {:ok, %QuackDB.Result{columns: ["name"], rows: [["mallard"]], num_rows: 1}} =
             QuackDB.query(connection, "SELECT name FROM #{table}")
  end

  test "formats raw query parameters against a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{rows: [["duck", 42, ~D[2024-01-02]]]}} =
             QuackDB.query(connection, "SELECT ? AS name, ? AS n, ? AS d", [
               "duck",
               42,
               ~D[2024-01-02]
             ])

    assert {:ok, %QuackDB.Result{rows: [["Robert'); DROP TABLE users;--"]]}} =
             QuackDB.query(connection, "SELECT ? AS safe", ["Robert'); DROP TABLE users;--"])
  end
end
