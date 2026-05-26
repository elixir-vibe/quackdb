defmodule QuackDB.ServerTest do
  use ExUnit.Case, async: true

  test "child_spec uses provided name as supervisor id" do
    assert %{id: MyApp.DuckDB, start: {QuackDB.Server, :start_link, [options]}} =
             QuackDB.Server.child_spec(name: MyApp.DuckDB, token: "secret")

    assert options[:name] == MyApp.DuckDB
    assert options[:token] == "secret"
  end

  test "child_specs builds matching server and client child specs" do
    [server_spec, client_spec] =
      QuackDB.Server.child_specs(
        server: [name: MyApp.DuckDB, endpoint: "quack:localhost:9500", token: "secret"],
        client: [name: MyApp.QuackDB, pool_size: 2]
      )

    assert %{id: MyApp.DuckDB, start: {QuackDB.Server, :start_link, [server_options]}} =
             server_spec

    assert server_options[:endpoint] == "quack:localhost:9500"
    assert server_options[:uri] == "http://[::1]:9500"
    assert server_options[:token] == "secret"

    assert %{
             start:
               {DBConnection.ConnectionPool, :start_link,
                [{QuackDB.DBConnection, client_options}]}
           } = client_spec

    assert client_options[:name] == MyApp.QuackDB
    assert client_options[:pool_size] == 2
    assert client_options[:uri] == "http://[::1]:9500"
    assert client_options[:token] == "secret"
  end

  test "child_specs generates a shared token when none is provided" do
    [server_spec, client_spec] =
      QuackDB.Server.child_specs(server: [name: MyApp.DuckDB], client: [])

    %{start: {QuackDB.Server, :start_link, [server_options]}} = server_spec

    %{start: {DBConnection.ConnectionPool, :start_link, [{QuackDB.DBConnection, client_options}]}} =
      client_spec

    assert is_binary(server_options[:token])
    assert byte_size(server_options[:token]) > 20
    assert client_options[:token] == server_options[:token]
  end

  test "info exposes generated boot SQL and endpoint-derived URI" do
    server =
      start_supervised!(
        {QuackDB.Server,
         endpoint: "quack:127.0.0.1:9501",
         token: "secret",
         wait: false,
         daemon_command: {"tail", ["-f", "/dev/null"]}}
      )

    assert QuackDB.Server.uri(server) == "http://127.0.0.1:9501"

    assert %{boot_sql: boot_sql} = QuackDB.Server.info(server)
    assert boot_sql =~ "LOAD quack; SET threads = "
    assert boot_sql =~ " SET GLOBAL quack_fetch_batch_chunks = 4; "
    assert boot_sql =~ "CALL quack_serve('quack:127.0.0.1:9501', token = 'secret');"
  end

  test "custom URI overrides endpoint-derived URI" do
    server =
      start_supervised!(
        {QuackDB.Server,
         endpoint: "quack:localhost:9502",
         uri: "http://example.invalid:9502",
         token: "secret",
         wait: false,
         daemon_command: {"tail", ["-f", "/dev/null"]}}
      )

    assert QuackDB.Server.uri(server) == "http://example.invalid:9502"
  end

  test "custom settings are emitted before quack_serve" do
    server =
      start_supervised!(
        {QuackDB.Server,
         token: "secret",
         settings: [threads: 2],
         global_settings: [quack_fetch_batch_chunks: 1],
         wait: false,
         daemon_command: {"tail", ["-f", "/dev/null"]}}
      )

    assert %{
             boot_sql:
               "LOAD quack; SET threads = 2; SET GLOBAL quack_fetch_batch_chunks = 1; CALL quack_serve('quack:localhost', token = 'secret');"
           } = QuackDB.Server.info(server)
  end

  test "load_quack? false omits LOAD statement" do
    server =
      start_supervised!(
        {QuackDB.Server,
         token: "secret",
         load_quack?: false,
         settings: [],
         global_settings: [],
         wait: false,
         daemon_command: {"tail", ["-f", "/dev/null"]}}
      )

    assert %{boot_sql: "CALL quack_serve('quack:localhost', token = 'secret');"} =
             QuackDB.Server.info(server)
  end

  test "missing DuckDB executable returns a clean start error" do
    Process.flag(:trap_exit, true)

    assert {:error, {:enoent, _stack}} =
             QuackDB.Server.start_link(duckdb: "definitely_missing_duckdb_exe", wait: false)
  end

  test "managed DuckDB uses downloaded binary path" do
    path = System.find_executable("duckdb")

    if path do
      server =
        start_supervised!(
          {QuackDB.Server,
           duckdb: :managed,
           duckdb_options: [path: path],
           boot_sql: "ignored",
           token: "secret",
           wait: false,
           daemon_command: {"tail", ["-f", "/dev/null"]}}
        )

      assert %{duckdb: ^path} = QuackDB.Server.info(server)
    end
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
