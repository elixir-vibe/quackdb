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
end
