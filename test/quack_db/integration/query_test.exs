defmodule QuackDB.Integration.QueryTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "queries a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["n"], rows: [[1]], num_rows: 1}} =
             QuackDB.query(connection, "SELECT 1 AS n")
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
    assert List.last(result.rows) == [49_999]
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
             QuackDB.query(connection, "CREATE TEMP TABLE #{table}(id INTEGER, name VARCHAR)")

    assert create.metadata[:duckdb_columns] == ["Count"]
    assert create.metadata[:duckdb_rows] == []

    assert {:ok, %QuackDB.Result{command: :insert, columns: nil, rows: nil, num_rows: 2} = insert} =
             QuackDB.query(connection, "INSERT INTO #{table} VALUES (1, 'duck'), (2, 'goose')")

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
