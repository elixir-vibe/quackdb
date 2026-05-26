defmodule QuackDB.Integration.SessionFailureTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "queries fail cleanly after the local Quack server session is lost" do
    token = "quackdb_session_failure_#{System.unique_integer([:positive])}"
    port = 21_000 + System.unique_integer([:positive, :monotonic])
    endpoint = "quack:localhost:#{port}"
    uri = "http://[::1]:#{port}"

    server =
      start_supervised!(
        {QuackDB.Server,
         token: token, endpoint: endpoint, uri: uri, wait: true, wait_timeout: 10_000}
      )

    connection = start_supervised!({QuackDB, uri: QuackDB.Server.uri(server), token: token})

    assert {:ok, %QuackDB.Result{rows: [[1]]}} = QuackDB.query(connection, "SELECT 1")

    :ok = GenServer.stop(server)

    assert {:error, %QuackDB.Error{source: source}} = QuackDB.query(connection, "SELECT 2")
    assert source in [:transport, :server, :protocol]
  end
end
