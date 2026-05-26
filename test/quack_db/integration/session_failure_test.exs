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

    assert {:error, %QuackDB.Error{source: source}} = eventually_lost_session(connection)
    assert source in [:transport, :server, :protocol]
  end

  defp eventually_lost_session(connection) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    eventually_lost_session(connection, deadline, nil)
  end

  defp eventually_lost_session(connection, deadline, last_result) do
    case QuackDB.query(connection, "SELECT 2") do
      {:error, %QuackDB.Error{}} = error ->
        error

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          other
        else
          Process.sleep(50)
          eventually_lost_session(connection, deadline, other || last_result)
        end
    end
  end
end
