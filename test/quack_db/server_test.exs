defmodule QuackDB.ServerTest do
  use ExUnit.Case, async: true

  alias QuackDB.ServerFixture

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
    assert boot_sql =~ "INSTALL quack; LOAD quack; SET threads = "
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
               "INSTALL quack; LOAD quack; SET threads = 2; SET GLOBAL quack_fetch_batch_chunks = 1; CALL quack_serve('quack:localhost', token = 'secret');"
           } = QuackDB.Server.info(server)
  end

  test "recovery_mode attaches persistent databases without WAL writes" do
    server =
      start_supervised!(
        {QuackDB.Server,
         database: "/tmp/rebuildable.duckdb",
         recovery_mode: :no_wal_writes,
         attach_as: :index,
         token: "secret",
         settings: [],
         global_settings: [],
         wait: false,
         daemon_command: {"tail", ["-f", "/dev/null"]}}
      )

    assert %{
             database: "/tmp/rebuildable.duckdb",
             boot_sql:
               "ATTACH '/tmp/rebuildable.duckdb' AS \"index\" (RECOVERY_MODE no_wal_writes); USE \"index\"; INSTALL quack; LOAD quack; CALL quack_serve('quack:localhost', token = 'secret');"
           } = QuackDB.Server.info(server)
  end

  test "install_quack? false skips idempotent INSTALL statement" do
    server =
      start_supervised!(
        {QuackDB.Server,
         token: "secret",
         install_quack?: false,
         settings: [],
         global_settings: [],
         wait: false,
         daemon_command: {"tail", ["-f", "/dev/null"]}}
      )

    assert %{boot_sql: "LOAD quack; CALL quack_serve('quack:localhost', token = 'secret');"} =
             QuackDB.Server.info(server)
  end

  test "load_quack? false omits extension statements" do
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

  test "default daemon command keeps boot SQL token out of arguments" do
    script = sleep_script!()

    server =
      start_supervised!(
        {QuackDB.Server,
         duckdb: System.find_executable("elixir"),
         database: script,
         token: "secret-token",
         wait: false}
      )

    state = :sys.get_state(server)

    refute Enum.any?(state.daemon_args, &String.contains?(&1, "secret-token"))
    refute Enum.member?(state.daemon_args, "-cmd")
    assert Enum.member?(state.daemon_args, "-init")
    assert is_binary(state.boot_sql_path)
    assert File.read!(state.boot_sql_path) =~ "token = 'secret-token'"

    stop_supervised!(QuackDB.Server)
    refute File.exists?(state.boot_sql_path)
  end

  test "boot_sql_source: :cmd keeps the legacy argument form when explicitly requested" do
    script = sleep_script!()

    server =
      start_supervised!(
        {QuackDB.Server,
         duckdb: System.find_executable("elixir"),
         database: script,
         token: "secret-token",
         wait: false,
         boot_sql_source: :cmd}
      )

    state = :sys.get_state(server)

    assert Enum.member?(state.daemon_args, "-cmd")
    assert Enum.any?(state.daemon_args, &String.contains?(&1, "token = 'secret-token'"))
    assert is_nil(state.boot_sql_path)
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

  @tag capture_log: true
  test "startup reports daemon exit promptly with its output and status" do
    fixture = ServerFixture.start!("boot failed")
    error = ServerFixture.finish!(fixture, 7)

    assert error.code == :server_start_failed
    assert error.metadata.exit_reason == {:exit_status, 7}
    assert error.metadata.output_tail == fixture.output
  end

  @tag capture_log: true
  test "preserves exit status and custom mappings when MuonTrap supplies the status" do
    error = startup_error!(daemon_command: {"sh", ["-c", "exit 7"]})
    assert error.metadata.exit_reason == {:exit_status, 7}

    error =
      startup_error!(
        daemon_command: {"sh", ["-c", "exit 2"]},
        daemon_options: [exit_status_to_reason: fn status -> {:custom_exit, status} end]
      )

    assert error.metadata.exit_reason == {:custom_exit, 2}
  end

  @tag capture_log: true
  test "normal daemon exit before readiness is a startup failure" do
    error = startup_error!(daemon_command: {"sh", ["-c", "exit 0"]})
    assert error.code == :server_start_failed
    assert error.metadata.exit_reason == :normal
  end

  @tag capture_log: true
  test "classifies lock conflicts but not unrelated file errors" do
    message =
      "IO Error: Could not set lock on file db: Conflicting lock is held by another process"

    error = message |> ServerFixture.start!() |> ServerFixture.finish!()

    assert error.code == :database_locked
    assert error.metadata.output_tail =~ message

    error =
      "Could not set lock on file: Permission denied"
      |> ServerFixture.start!()
      |> ServerFixture.finish!()

    assert error.code == :server_start_failed
  end

  @tag capture_log: true
  test "startup output is bounded and redacts tokens before truncation" do
    token = "private'\"token"
    output = String.duplicate("old output\n", 1_000) <> token <> "\nlatest output"

    error = output |> ServerFixture.start!(token: token) |> ServerFixture.finish!()

    assert byte_size(error.metadata.output_tail) <= 8_192
    assert error.metadata.output_tail =~ "[REDACTED]\nlatest output\n"
    refute error.metadata.output_tail =~ token
  end

  @tag capture_log: true
  test "endpoint mentions and incomplete result rows do not signal readiness" do
    for output <- ["Error binding quack:localhost", "quack:localhost,not-a-ready-row"] do
      error = output |> ServerFixture.start!() |> ServerFixture.finish!()

      assert error.code == :server_start_failed
    end
  end

  @tag capture_log: true
  test "preserves an explicitly induced daemon failure without inventing an exit status" do
    fixture = ServerFixture.start!("transport failed")
    Process.exit(fixture.daemon, :epipe)
    error = ServerFixture.await_error!(fixture)

    assert error.code == :server_start_failed
    assert error.metadata.exit_reason == :epipe
    assert error.metadata.output_tail == fixture.output
  end

  @tag capture_log: true
  test "daemon exit interrupts a stalled readiness probe without losing diagnostics" do
    fixture = ServerFixture.start!("boot failed", uri: stalled_endpoint!(), poll_interval: 1)
    assert_receive :probe_connected, 5_000
    {probe, monitor} = ServerFixture.suspend_probe!(fixture)

    error = ServerFixture.finish!(fixture, 7)

    assert error.code == :server_start_failed
    assert error.metadata.exit_reason == {:exit_status, 7}
    assert error.metadata.output_tail == fixture.output
    assert_receive {:DOWN, ^monitor, :process, ^probe, :killed}, 5_000
    assert_receive :probe_closed, 5_000
  end

  test "late probe reports do not crash a server that has become ready" do
    server =
      start_supervised!(
        {QuackDB.Server,
         daemon_command:
           {"sh",
            ["-c", "echo 'quack:localhost,http://localhost:9494,secret'; exec tail -f /dev/null"]},
         token: "secret",
         uri: "http://127.0.0.1:1",
         poll_interval: 10_000}
      )

    send(server, {:quackdb_server_probe_error, self(), :closed})
    assert QuackDB.Server.uri(server) == "http://127.0.0.1:1"
  end

  @tag capture_log: true
  test "deadline cancels a stalled probe and closes its socket" do
    # The only real-clock deadline test. The producer is never released and the
    # probe cannot finish by itself. Startup must end through its own deadline.
    fixture =
      ServerFixture.start!("still booting",
        uri: stalled_endpoint!(fail_first: true),
        poll_interval: 1,
        wait_timeout: 5_000
      )

    assert_receive :probe_connected, 5_000
    {probe, monitor} = ServerFixture.suspend_probe!(fixture)
    error = ServerFixture.await_error!(fixture)

    assert error.code == :server_start_timeout
    assert error.metadata.output_tail == fixture.output
    assert error.metadata.last_error
    refute Map.has_key?(error.metadata, :exit_reason)
    assert_receive {:DOWN, ^monitor, :process, ^probe, :killed}, 5_000
    assert_receive :probe_closed, 5_000
  end

  @tag capture_log: true
  test "bounded diagnostic tails remain valid UTF-8 and JSON encodable" do
    output = String.duplicate("🦆\n", 2_000)

    for suffix <- ["", <<255>> <> "invalid byte"] do
      fixture = ServerFixture.start!(output <> suffix)
      # The uncorrected byte slice must be invalid, independent of random seed.
      raw_tail = binary_part(fixture.output, byte_size(fixture.output) - 8_192, 8_192)
      refute String.valid?(raw_tail)
      error = ServerFixture.finish!(fixture)
      tail = error.metadata.output_tail

      assert byte_size(tail) <= 8_192
      assert String.valid?(tail)
      assert JSON.decode!(JSON.encode!(%{output_tail: tail})) == %{"output_tail" => tail}
      if suffix != "", do: assert(tail =~ "�invalid byte\n")
    end
  end

  @tag capture_log: true
  test "captures output while preserving logger callbacks and exit status overrides" do
    parent = self()

    fixture =
      ServerFixture.start!("custom logging",
        daemon_options: [
          logger_fun: fn line -> send(parent, {:logged, line}) end,
          exit_status_to_reason: fn status -> {:custom_exit, status} end
        ]
      )

    error = ServerFixture.finish!(fixture, 2)

    assert_receive {:logged, "custom logging"}
    assert error.metadata.output_tail == fixture.output
    assert error.metadata.exit_reason == {:custom_exit, 2}
  end

  test "captures output without bypassing log_output transforms and metadata" do
    log =
      ExUnit.CaptureLog.capture_log([format: "$metadata$message", metadata: [:review]], fn ->
        fixture =
          ServerFixture.start!("logging failure",
            daemon_options: [
              log_output: :warning,
              log_prefix: "prefix: ",
              log_transform: &String.upcase/1,
              logger_metadata: [review: "kept"]
            ]
          )

        error = ServerFixture.finish!(fixture, 2)
        assert error.metadata.output_tail == fixture.output
      end)

    assert log =~ "prefix: LOGGING FAILURE"
    assert log =~ "review=kept"
  end

  test "child_specs accepts a Repo child tuple and retains shared credentials" do
    [server_spec, repo_spec] =
      QuackDB.Server.child_specs(
        server: [endpoint: "quack:127.0.0.1:9503"],
        client: {QuackDB.IntegrationRepo, pool_size: 2}
      )

    assert %{start: {QuackDB.Server, :start_link, [server_options]}} = server_spec
    assert %{start: {QuackDB.IntegrationRepo, :start_link, [options]}} = repo_spec
    assert options[:uri] == "http://127.0.0.1:9503"
    assert options[:token] == server_options[:token]
    assert options[:pool_size] == 2
    assert is_binary(options[:token])
    assert repo_spec == Supervisor.child_spec({QuackDB.IntegrationRepo, options}, [])

    assert [^server_spec, ^repo_spec] =
             QuackDB.Server.child_specs(
               server: server_options,
               client: {QuackDB.IntegrationRepo, options}
             )
  end

  test "pairing respects client defaults and server overrides" do
    client = {QuackDB.IntegrationRepo, uri: "http://example.test", token: "client"}
    [server, _repo] = QuackDB.Server.child_specs(client: client)
    assert %{start: {QuackDB.Server, :start_link, [options]}} = server
    assert options[:uri] == "http://example.test"
    assert options[:token] == "client"

    [_server, repo] =
      QuackDB.Server.child_specs(
        server: [uri: "http://server.test", token: "server"],
        client: client
      )

    assert %{start: {QuackDB.IntegrationRepo, :start_link, [options]}} = repo
    assert options[:uri] == "http://server.test"
    assert options[:token] == "server"
  end

  test "child_specs rejects invalid client shapes" do
    for client <- [QuackDB.IntegrationRepo, {QuackDB.IntegrationRepo, %{}}, :invalid] do
      assert_raise ArgumentError, ~r/expected :client/, fn ->
        QuackDB.Server.child_specs(client: client)
      end
    end
  end

  defp stalled_endpoint!(options \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         if Keyword.get(options, :fail_first, false) do
           {:ok, socket} = :gen_tcp.accept(listener)

           :ok =
             :gen_tcp.send(
               socket,
               "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
             )

           :ok = :gen_tcp.close(socket)
         end

         {:ok, socket} = :gen_tcp.accept(listener)
         send(parent, :probe_connected)
         await_socket_close(socket)
         send(parent, :probe_closed)
       end}
    )

    "http://127.0.0.1:#{port}"
  end

  defp await_socket_close(socket) do
    case :gen_tcp.recv(socket, 0, 15_000) do
      {:ok, _request} -> await_socket_close(socket)
      {:error, :closed} -> :ok
      other -> flunk("expected readiness probe socket to close, got: #{inspect(other)}")
    end
  end

  defp startup_error!(options) do
    Process.flag(:trap_exit, true)

    options =
      Keyword.merge([uri: "http://127.0.0.1:1", token: "secret", wait_timeout: 2_000], options)

    assert {:error, {%QuackDB.Error{} = error, _stack}} = QuackDB.Server.start_link(options)
    error
  end

  defp sleep_script! do
    path =
      Path.join(
        System.tmp_dir!(),
        "quackdb-server-test-#{System.unique_integer([:positive])}.exs"
      )

    File.write!(path, "Process.sleep(:infinity)\n")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
