defmodule QuackDB.Integration.ServerTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "starts a local DuckDB Quack server under supervision" do
    token = "quackdb_server_test_#{System.unique_integer([:positive])}"
    port = 19_000 + System.unique_integer([:positive, :monotonic])
    endpoint = "quack:localhost:#{port}"
    uri = "http://[::1]:#{port}"

    server =
      start_supervised!(
        {QuackDB.Server,
         token: token, endpoint: endpoint, uri: uri, wait: true, wait_timeout: 10_000}
      )

    connection = start_supervised!({QuackDB, uri: QuackDB.Server.uri(server), token: token})

    assert {:ok, %QuackDB.Result{rows: [[1]]}} = QuackDB.query(connection, "SELECT 1 AS n")
    assert is_integer(QuackDB.Server.os_pid(server))
  end

  @tag :managed_duckdb
  test "starts a managed DuckDB binary server" do
    duckdb = System.find_executable("duckdb")

    if duckdb do
      token = "quackdb_managed_server_test_#{System.unique_integer([:positive])}"
      port = 20_000 + System.unique_integer([:positive, :monotonic])
      endpoint = "quack:localhost:#{port}"
      uri = "http://[::1]:#{port}"

      server =
        start_supervised!(
          {QuackDB.Server,
           duckdb: :managed,
           duckdb_options: [path: duckdb],
           token: token,
           endpoint: endpoint,
           uri: uri,
           wait: true,
           wait_timeout: 20_000}
        )

      connection = start_supervised!({QuackDB, uri: QuackDB.Server.uri(server), token: token})

      assert {:ok, %QuackDB.Result{rows: [[42]]}} = QuackDB.query(connection, "SELECT 42 AS n")
      assert QuackDB.Server.info(server).duckdb == duckdb
    end
  end
end
