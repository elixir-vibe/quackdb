defmodule QuackDB.ServerTest do
  use ExUnit.Case, async: true

  test "child_spec uses provided name as supervisor id" do
    assert %{id: MyApp.DuckDB, start: {QuackDB.Server, :start_link, [options]}} =
             QuackDB.Server.child_spec(name: MyApp.DuckDB, token: "secret")

    assert options[:name] == MyApp.DuckDB
    assert options[:token] == "secret"
  end

  test "starts a supervised MuonTrap daemon without waiting" do
    server =
      start_supervised!(
        {QuackDB.Server,
         duckdb: "tail",
         database: "ignored",
         boot_sql: "ignored",
         token: "secret",
         wait: false,
         daemon_command: {"tail", ["-f", "/dev/null"]}}
      )

    assert QuackDB.Server.uri(server) == "http://[::1]:9494"
    assert QuackDB.Server.token(server) == "secret"
    assert QuackDB.Server.os_pid(server) == :error or is_integer(QuackDB.Server.os_pid(server))

    assert %{duckdb: "tail", database: "ignored", token: "secret", os_pid: os_pid} =
             QuackDB.Server.info(server)

    assert os_pid == :error or is_integer(os_pid)
    assert %{output_byte_count: _} = QuackDB.Server.statistics(server)
  end
end
