defmodule QuackDB.Integration.QuackServerTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "queries a real Quack server" do
    uri = System.fetch_env!("QUACKDB_TEST_URI")
    token = System.get_env("QUACKDB_TEST_TOKEN", "")

    start_options = [uri: uri, token: token]
    connection = start_supervised!({QuackDB, start_options})

    assert {:ok, %QuackDB.Result{columns: ["n"], rows: [[1]], num_rows: 1}} =
             QuackDB.query(connection, "SELECT 1 AS n")
  end

  test "decodes mixed scalar results from a real Quack server" do
    uri = System.fetch_env!("QUACKDB_TEST_URI")
    token = System.get_env("QUACKDB_TEST_TOKEN", "")

    start_options = [uri: uri, token: token]
    connection = start_supervised!({QuackDB, start_options})

    assert {:ok, %QuackDB.Result{columns: ["ok", "name", "amount"]} = result} =
             QuackDB.query(
               connection,
               "SELECT true AS ok, 'duck' AS name, 12.5::DOUBLE AS amount"
             )

    assert result.rows == [[true, "duck", 12.5]]
  end
end
