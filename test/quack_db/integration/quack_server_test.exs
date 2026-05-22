defmodule QuackDB.Integration.QuackServerTest do
  use ExUnit.Case, async: false

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

  test "streams large result sets from a real Quack server" do
    connection = start_connection!()

    assert {:ok, rows} =
             DBConnection.transaction(connection, fn tx ->
               tx
               |> QuackDB.stream("SELECT i::INTEGER AS n FROM range(0, 50000) t(i)", [],
                 max_rows: 1000
               )
               |> Enum.flat_map(& &1.rows)
             end)

    assert length(rows) == 50_000
    assert hd(rows) == [0]
    assert List.last(rows) == [49_999]
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

  test "transactions roll back through DBConnection" do
    connection = start_connection!()
    table = "qrollback_#{System.unique_integer([:positive])}"

    assert {:error, :rolled_back} =
             DBConnection.transaction(connection, fn tx ->
               QuackDB.query!(tx, "CREATE TEMP TABLE #{table}(v INTEGER)")
               QuackDB.query!(tx, "INSERT INTO #{table} VALUES (1)")
               DBConnection.rollback(tx, :rolled_back)
             end)

    assert {:error, %QuackDB.Error{message: message}} =
             QuackDB.query(connection, "SELECT count(*) FROM #{table}")

    assert message =~ "does not exist"
  end

  test "propagates server errors with query context" do
    connection = start_connection!()

    assert {:error, %QuackDB.Error{} = error} = QuackDB.query(connection, "SELEC broken")
    assert error.message =~ "syntax error"
    assert error.query == "SELEC broken"
    assert is_binary(error.connection_id)
  end

  defp start_connection! do
    uri = System.fetch_env!("QUACKDB_TEST_URI")
    token = System.get_env("QUACKDB_TEST_TOKEN", "")

    start_supervised!({QuackDB, uri: uri, token: token})
  end
end
