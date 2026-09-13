defmodule QuackDB.Integration.ServerTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "starts a local DuckDB Quack server under supervision" do
    token = "quackdb_server_test_#{System.unique_integer([:positive])}"
    port = 19_000 + System.unique_integer([:positive, :monotonic])
    endpoint = "quack:127.0.0.1:#{port}"
    uri = "http://127.0.0.1:#{port}"

    server =
      start_supervised!(
        {QuackDB.Server,
         duckdb: test_duckdb(),
         token: token,
         endpoint: endpoint,
         uri: uri,
         wait: true,
         wait_timeout: 10_000}
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
      endpoint = "quack:127.0.0.1:#{port}"
      uri = "http://127.0.0.1:#{port}"

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

  @tag :tmp_dir
  @tag capture_log: true
  test "reports a real database lock conflict instead of a readiness timeout", %{tmp_dir: dir} do
    database = Path.join(dir, "locked.duckdb")
    start_supervised!({QuackDB.Server, local_options(database)})
    Process.flag(:trap_exit, true)

    result =
      QuackDB.Server.start_link(Keyword.put(local_options(database), :wait_timeout, 30_000))

    assert {:error, {%QuackDB.Error{code: :database_locked, metadata: metadata}, _stack}} = result
    assert metadata.database == database
    assert metadata.output_tail =~ "Could not set lock on file"
    # The OS/MuonTrap boundary does not guarantee an exit status on pipe failure.
    # Exact status mapping and :epipe propagation are tested separately with a
    # controlled producer. This test verifies the real lock classification.
    assert Map.has_key?(metadata, :exit_reason)
  end

  @tag capture_log: true
  test "recognizes the real CSV readiness row with quoted tokens and custom logging" do
    options = local_options(":memory:") |> Keyword.put(:token, "comma,quote\"token")
    # A probe cannot succeed at this URI. Startup must recognize the CLI row.
    options =
      options ++
        [
          uri: "http://127.0.0.1:1",
          poll_interval: 10_000,
          wait_timeout: 2_000,
          daemon_options: [log_output: :debug]
        ]

    server = start_supervised!({QuackDB.Server, options})
    assert Process.alive?(server)
  end

  test "falls back to a protocol probe when a custom daemon emits no readiness row" do
    server = start_supervised!({QuackDB.Server, local_options(":memory:")})

    options = [
      uri: QuackDB.Server.uri(server),
      token: QuackDB.Server.token(server),
      daemon_command: {"tail", ["-f", "/dev/null"]},
      poll_interval: 1,
      wait_timeout: 2_000
    ]

    probe_server =
      start_supervised!(Supervisor.child_spec({QuackDB.Server, options}, id: :probe_server))

    assert Process.alive?(probe_server)
  end

  test "pairs a local server with an Ecto Repo and retains credentials on restart" do
    [server_spec, repo_spec] =
      QuackDB.Server.child_specs(
        server: local_options(":memory:"),
        client: {QuackDB.IntegrationRepo, pool_size: 1, log: false}
      )

    server = start_supervised!(server_spec)
    start_supervised!(repo_spec)
    assert %{rows: [[42]]} = QuackDB.IntegrationRepo.query!("SELECT 42")
    token = QuackDB.Server.token(server)
    stop_supervised!(QuackDB.IntegrationRepo)
    stop_and_wait!(server)

    restarted = start_supervised!(server_spec)
    assert QuackDB.Server.token(restarted) == token
    start_supervised!(repo_spec)
    assert %{rows: [[43]]} = QuackDB.IntegrationRepo.query!("SELECT 43")
  end

  @tag :tmp_dir
  test "an explicitly checkpointed quiescent database can be copied after stop", %{tmp_dir: dir} do
    database = Path.join(dir, "original.duckdb")
    server = start_supervised!({QuackDB.Server, local_options(database)})

    connection =
      start_supervised!(
        {QuackDB, uri: QuackDB.Server.uri(server), token: QuackDB.Server.token(server)}
      )

    QuackDB.query!(connection, "CREATE TABLE persisted AS SELECT 42 AS value")
    QuackDB.Storage.checkpoint!(connection)
    stop_supervised!(DBConnection.ConnectionPool)
    stop_and_wait!(server)

    refute File.exists?(database <> ".wal")
    copy = Path.join(dir, "copy.duckdb")
    File.cp!(database, copy)
    assert {"42\n", 0} = read_persisted(copy)
  end

  @tag :tmp_dir
  @tag capture_log: true
  test "committed WAL data survives abrupt server shutdown", %{tmp_dir: dir} do
    database = Path.join(dir, "recovery.duckdb")
    spec = Supervisor.child_spec({QuackDB.Server, local_options(database)}, restart: :temporary)
    server = start_supervised!(spec)
    os_pid = QuackDB.Server.os_pid(server)

    connection =
      start_supervised!(
        {QuackDB, uri: QuackDB.Server.uri(server), token: QuackDB.Server.token(server)}
      )

    QuackDB.query!(connection, "CREATE TABLE persisted AS SELECT 42 AS value")
    assert File.stat!(database <> ".wal").size > 0
    stop_supervised!(DBConnection.ConnectionPool)
    monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}
    wait_os_exit!(os_pid)

    # Do not delete the WAL: reopening the original database recovers it.
    assert File.stat!(database <> ".wal").size > 0
    assert {"42\n", 0} = read_persisted(database)
  end

  defp local_options(database) do
    {:ok, socket} = :gen_tcp.listen(0, [:inet, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    [duckdb: test_duckdb(), database: database, endpoint: "quack:127.0.0.1:#{port}"]
  end

  defp stop_and_wait!(server) do
    os_pid = QuackDB.Server.os_pid(server)
    stop_supervised!(QuackDB.Server)
    wait_os_exit!(os_pid)
  end

  defp wait_os_exit!(os_pid, attempts \\ 100) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} when attempts > 0 ->
        Process.sleep(20)
        wait_os_exit!(os_pid, attempts - 1)

      {_output, 0} ->
        flunk("MuonTrap OS process did not exit")

      {_output, _status} ->
        :ok
    end
  end

  defp read_persisted(database) do
    binary =
      case test_duckdb() do
        :managed -> QuackDB.Binary.path!()
        path -> path
      end

    System.cmd(
      binary,
      [database, "-csv", "-noheader", "-init", "/dev/null", "-c", "SELECT value FROM persisted"],
      stderr_to_stdout: true
    )
  end

  defp test_duckdb do
    case System.get_env("QUACKDB_TEST_DUCKDB") do
      "managed" -> :managed
      path when is_binary(path) and path != "" -> path
      _other -> "duckdb"
    end
  end
end
