defmodule QuackDB.Server do
  @moduledoc """
  Supervises a local DuckDB Quack server process with MuonTrap.

  This is a convenience for local development, tests, demos, and notebooks. It
  starts the external `duckdb` executable and serves DuckDB's Quack HTTP
  protocol. It is not an embedded DuckDB driver and is not required when your
  Quack server runs elsewhere.

      children =
        QuackDB.Server.child_specs(
          server: [name: MyApp.DuckDB, duckdb: :managed, endpoint: "quack:localhost:9494"],
          client: [name: MyApp.QuackDB, pool_size: 5]
        )

  Use `duckdb: :managed` to download and cache DuckDB's official CLI binary via
  `QuackDB.Binary`. Pass `duckdb: "/path/to/duckdb"` or set
  `QUACKDB_BINARY_PATH` when you want to provide the executable yourself.

  `child_specs/1` generates one shared random token when neither side provides
  `:token`, then injects the same token and URI into the server and client specs.

  By default the server runs DuckDB directly under MuonTrap with `-interactive`
  so the process stays alive after `quack_serve/2` starts. It installs and loads
  the `quack` extension before serving, unless `load_quack?: false` is set. Boot
  SQL is written to an Elixir-owned temporary init file by default so generated
  local tokens are not embedded in the operating-system argument vector.

  Startup waits until the Quack endpoint is ready. For the default DuckDB CLI
  command, readiness is detected from the `quack_serve/2` result row printed to
  stdout. `:poll_interval` is only the fallback probe interval for custom daemon
  output handling or custom commands that do not expose that row. Probes run in
  a cancellable task so daemon exits and output remain visible while HTTP waits;
  the startup deadline also cancels an in-flight probe.

  Startup failures report `:server_start_failed`, `:server_start_timeout`, or
  `:database_locked` for recognized DuckDB file-lock conflicts. Error metadata
  includes `:database`, `:uri`, `:last_error`, an `:output_tail` of at most 8 KiB,
  and `:exit_reason` when the daemon exits. The retained output redacts the
  server token, replaces invalid UTF-8, and truncates on a character boundary.
  Explicitly configured logger callbacks still receive original output.
  Capture is best-effort, newline-delimited MuonTrap output; disabling
  stderr forwarding can omit diagnostics. Other secrets in custom boot output
  are not automatically redacted.

  Stopping this process signals the daemon; it does not run `CHECKPOINT` or
  guarantee an immediately copyable database file. Preserve a remaining WAL for
  recovery. Quiesce writers and explicitly checkpoint before a single-file copy,
  then stop clients and the supervised server and verify OS-process termination.
  A supervised server is a permanent child: use `Supervisor.terminate_child/2`
  rather than `GenServer.stop/1` to stop it without automatic restart.
  """

  use GenServer

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.Disconnect
  alias QuackDB.Protocol.Message.ErrorResponse

  require Logger

  @ready_check_timeout 1_000
  @output_tail_bytes 8_192

  defstruct [
    :daemon,
    :duckdb,
    :database,
    :endpoint,
    :uri,
    :token,
    :boot_sql,
    :boot_sql_path,
    :boot_sql_dir,
    :daemon_command,
    :daemon_args,
    :daemon_options
  ]

  @type option ::
          {:name, GenServer.name()}
          | {:duckdb, String.t() | :managed}
          | {:duckdb_options, keyword()}
          | {:database, String.t()}
          | {:endpoint, String.t()}
          | {:uri, String.t()}
          | {:token, String.t()}
          | {:load_quack?, boolean()}
          | {:install_quack?, boolean()}
          | {:boot_sql, String.t()}
          | {:boot_sql_source, :init_file | :cmd}
          | {:settings, keyword(QuackDB.SQL.parameter())}
          | {:global_settings, keyword(QuackDB.SQL.parameter())}
          | {:recovery_mode, :no_wal_writes | String.t()}
          | {:attach_as, atom() | String.t()}
          | {:wait, boolean()}
          | {:wait_timeout, timeout()}
          | {:poll_interval, pos_integer()}
          | {:daemon_options, Keyword.t()}
          | {:daemon_command, {String.t(), [String.t()]}}

  @doc """
  Returns matching server and client child specs, in startup order.

  `:server` is a list of Server options. `:client` accepts a keyword list for a
  QuackDB pool, or `{module, options}` for another client such as an Ecto Repo.
  The client must accept `:uri` and `:token` options. URI/token precedence is
  server, then client, then generated defaults. Both specs retain the generated
  credentials across restarts.

      alias QuackDB.Server

      children =
        Server.child_specs(
          server: [name: MyApp.DuckDB],
          client: {MyApp.Repo, pool_size: 2}
        )

  A `:rest_for_one` supervisor can restart the client when its server restarts
  and invalidates existing sessions.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(options \\ []) do
    server_options = Keyword.get(options, :server, [])
    {client_module, client_options} = client_child(Keyword.get(options, :client, []))
    endpoint = Keyword.get(server_options, :endpoint, "quack:localhost")

    uri =
      Keyword.get(server_options, :uri) || Keyword.get(client_options, :uri) ||
        default_uri(endpoint)

    token =
      Keyword.get(server_options, :token) || Keyword.get(client_options, :token) || random_token()

    server_options =
      server_options
      |> Keyword.put_new(:endpoint, endpoint)
      |> Keyword.put(:uri, uri)
      |> Keyword.put(:token, token)

    client_options = client_options |> Keyword.put(:uri, uri) |> Keyword.put(:token, token)
    [child_spec(server_options), Supervisor.child_spec({client_module, client_options}, [])]
  end

  defp client_child(options) when is_list(options), do: {QuackDB, options}

  defp client_child({module, options}) when is_atom(module) and is_list(options),
    do: {module, options}

  defp client_child(other) do
    raise ArgumentError,
          "expected :client to be a keyword list or {module, keyword}, got: #{inspect(other)}"
  end

  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: Keyword.get(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options \\ []) do
    {genserver_options, options} = Keyword.split(options, [:name])
    GenServer.start_link(__MODULE__, options, genserver_options)
  end

  @spec uri(GenServer.server()) :: String.t()
  def uri(server), do: GenServer.call(server, :uri)

  @spec token(GenServer.server()) :: String.t()
  def token(server), do: GenServer.call(server, :token)

  @spec info(GenServer.server()) :: map()
  def info(server), do: GenServer.call(server, :info)

  @doc """
  Returns the local MuonTrap wrapper's OS PID, not the DuckDB child PID.

  This does not identify the process holding a conflicting database file lock.
  """
  @spec os_pid(GenServer.server()) :: non_neg_integer() | :error
  def os_pid(server), do: GenServer.call(server, :os_pid)

  @spec statistics(GenServer.server()) :: map()
  def statistics(server), do: GenServer.call(server, :statistics)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    state = build_state(options)

    case start_daemon(state) do
      {:ok, daemon} ->
        state = %{state | daemon: daemon}

        try do
          if Keyword.get(options, :wait, true) do
            wait_ready!(
              state,
              Keyword.get(options, :wait_timeout, 5_000),
              Keyword.get(options, :poll_interval, 100)
            )

            cleanup_boot_sql_file(state)
          end

          {:ok, state}
        rescue
          error in [QuackDB.Error, RuntimeError, ErlangError, ArgumentError, File.Error] ->
            stop_daemon(daemon)
            cleanup_boot_sql_file(state)
            reraise error, __STACKTRACE__
        catch
          kind, reason ->
            stop_daemon(daemon)
            cleanup_boot_sql_file(state)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, reason} ->
        cleanup_boot_sql_file(state)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:uri, _from, state), do: {:reply, state.uri, state}
  def handle_call(:token, _from, state), do: {:reply, state.token, state}

  def handle_call(:info, _from, state) do
    info = %{
      duckdb: state.duckdb,
      database: state.database,
      endpoint: state.endpoint,
      uri: state.uri,
      token: state.token,
      boot_sql: state.boot_sql,
      boot_sql_path: state.boot_sql_path,
      os_pid: daemon_os_pid(state.daemon),
      statistics: daemon_statistics(state.daemon)
    }

    {:reply, info, state}
  end

  def handle_call(:os_pid, _from, state), do: {:reply, daemon_os_pid(state.daemon), state}
  def handle_call(:statistics, _from, state), do: {:reply, daemon_statistics(state.daemon), state}

  @impl true
  def handle_info({:quackdb_server_output, _line}, state), do: {:noreply, state}

  # A probe report can already be queued when stdout signals readiness.
  def handle_info({:quackdb_server_probe_error, _probe, _error}, state), do: {:noreply, state}

  def handle_info({:EXIT, daemon, reason}, %{daemon: daemon} = state) when is_pid(daemon),
    do: {:stop, reason, state}

  def handle_info({:EXIT, port, :normal}, state) when is_port(port), do: {:noreply, state}
  def handle_info({:EXIT, pid, :normal}, state) when is_pid(pid), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{daemon: daemon} = state) when is_pid(daemon) do
    stop_daemon(daemon)
    cleanup_boot_sql_file(state)
    :ok
  end

  def terminate(_reason, state) do
    cleanup_boot_sql_file(state)
    :ok
  end

  defp build_state(options) do
    duckdb = duckdb_path(options)
    database = Keyword.get(options, :database, ":memory:")
    endpoint = Keyword.get(options, :endpoint, "quack:localhost")
    uri = Keyword.get(options, :uri, default_uri(endpoint))
    token = Keyword.get_lazy(options, :token, &random_token/0)
    boot_sql = Keyword.get_lazy(options, :boot_sql, fn -> boot_sql(endpoint, token, options) end)
    daemon_options = daemon_options(options)

    cli_database = if Keyword.has_key?(options, :recovery_mode), do: ":memory:", else: database

    {command, args, boot_sql_file} = daemon_command(options, duckdb, cli_database, boot_sql)

    %__MODULE__{
      duckdb: duckdb,
      database: database,
      endpoint: endpoint,
      uri: uri,
      token: token,
      boot_sql: boot_sql,
      boot_sql_path: boot_sql_file && boot_sql_file.path,
      boot_sql_dir: boot_sql_file && boot_sql_file.dir,
      daemon_command: command,
      daemon_args: args,
      daemon_options: daemon_options
    }
  end

  defp duckdb_path(options) do
    case Keyword.get(options, :duckdb, "duckdb") do
      :managed -> QuackDB.Binary.path!(Keyword.get(options, :duckdb_options, []))
      path -> path
    end
  end

  defp daemon_options(options) do
    options
    |> Keyword.get(:daemon_options, [])
    |> Keyword.put_new(:stderr_to_stdout, true)
    |> Keyword.put_new(:log_prefix, "[quackdb-server] ")
    |> Keyword.put_new(:exit_status_to_reason, fn status -> {:exit_status, status} end)
  end

  defp daemon_command(options, duckdb, database, boot_sql) do
    case Keyword.fetch(options, :daemon_command) do
      {:ok, {command, args}} ->
        {command, args, nil}

      :error ->
        default_daemon_command(
          duckdb,
          database,
          boot_sql,
          Keyword.get(options, :boot_sql_source, :init_file)
        )
    end
  end

  defp default_daemon_command(duckdb, database, boot_sql, :init_file) do
    boot_sql_file = write_boot_sql_file!(boot_sql)

    {duckdb, [database, "-csv", "-noheader", "-interactive", "-init", boot_sql_file.path],
     boot_sql_file}
  end

  defp default_daemon_command(duckdb, database, boot_sql, :cmd) do
    {duckdb,
     [database, "-csv", "-noheader", "-interactive", "-init", "/dev/null", "-cmd", boot_sql], nil}
  end

  defp default_daemon_command(_duckdb, _database, _boot_sql, other) do
    raise ArgumentError,
          "expected :boot_sql_source to be :init_file or :cmd, got: #{inspect(other)}"
  end

  defp start_daemon(state) do
    MuonTrap.Daemon.start_link(
      state.daemon_command,
      state.daemon_args,
      daemon_options_with_ready_signal(state.daemon_options, self())
    )
  end

  defp stop_daemon(pid) when is_pid(pid), do: Process.exit(pid, :shutdown)

  defp write_boot_sql_file!(boot_sql) do
    dir = boot_sql_dir()
    path = Path.join(dir, "boot.sql")

    File.mkdir!(dir)
    chmod_best_effort(dir, 0o700)
    # DuckDB may execute -init before applying the CLI output-format flags.
    File.write!(path, [".mode csv\n.headers off\n", boot_sql])
    chmod_best_effort(path, 0o600)

    %{dir: dir, path: path}
  end

  defp boot_sql_dir do
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "quackdb-boot-#{suffix}")
  end

  defp chmod_best_effort(path, mode) do
    _ignored = File.chmod(path, mode)
    :ok
  end

  defp cleanup_boot_sql_file(%{boot_sql_path: path, boot_sql_dir: dir}) do
    if is_binary(path), do: File.rm(path)
    if is_binary(dir), do: File.rmdir(dir)
    :ok
  end

  defp cleanup_boot_sql_file(_state), do: :ok

  defp daemon_options_with_ready_signal(options, parent) do
    logger_fun = Keyword.get_lazy(options, :logger_fun, fn -> output_logger(options) end)

    Keyword.put(options, :logger_fun, fn line ->
      send(parent, {:quackdb_server_output, line})
      call_logger_fun(logger_fun, line)
    end)
  end

  defp output_logger(options) do
    case Keyword.get(options, :log_output) do
      nil ->
        fn _line -> :ok end

      level ->
        prefix = Keyword.fetch!(options, :log_prefix)
        transform = Keyword.get(options, :log_transform, &String.replace_invalid/1)
        fn line -> Logger.log(level, [prefix, transform.(line)]) end
    end
  end

  defp call_logger_fun(fun, line) when is_function(fun, 1), do: fun.(line)
  defp call_logger_fun({module, function, args}, line), do: apply(module, function, [line | args])

  defp wait_ready!(state, timeout, poll_interval) do
    deadline = System.monotonic_time(:millisecond) + timeout
    parent = self()
    probe = Task.async(fn -> probe_until_ready(state, poll_interval, parent) end)

    try do
      do_wait_ready!(state, deadline, probe, %{
        last_error: nil,
        output_tail: "",
        database_locked?: false
      })
    after
      Task.shutdown(probe, :brutal_kill)
    end
  end

  defp do_wait_ready!(state, deadline, probe, diagnostics) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      raise startup_error(
              state,
              diagnostics,
              :server_start_timeout,
              "DuckDB Quack server did not become ready"
            )
    end

    daemon = state.daemon
    %Task{ref: ref, pid: probe_pid} = probe

    receive do
      {:EXIT, ^daemon, reason} ->
        raise startup_error(
                state,
                Map.put(diagnostics, :exit_reason, reason),
                :server_start_failed,
                "DuckDB Quack server exited before becoming ready"
              )

      {^ref, :ok} ->
        :ok

      {:DOWN, ^ref, :process, ^probe_pid, reason} ->
        raise startup_error(
                state,
                Map.put(diagnostics, :probe_exit_reason, reason),
                :server_start_failed,
                "DuckDB Quack readiness probe failed"
              )

      {:quackdb_server_probe_error, ^probe_pid, error} ->
        do_wait_ready!(state, deadline, probe, %{diagnostics | last_error: error})

      {:quackdb_server_output, line} ->
        if ready_output?(line, state) do
          :ok
        else
          do_wait_ready!(state, deadline, probe, capture_output(diagnostics, line, state.token))
        end
    after
      max(remaining, 0) ->
        raise startup_error(
                state,
                diagnostics,
                :server_start_timeout,
                "DuckDB Quack server did not become ready"
              )
    end
  end

  defp probe_until_ready(state, poll_interval, parent) do
    Process.sleep(poll_interval)

    case check_ready(state) do
      :ok ->
        :ok

      {:error, error} ->
        send(parent, {:quackdb_server_probe_error, self(), error})
        probe_until_ready(state, poll_interval, parent)
    end
  end

  defp ready_output?(line, state) when is_binary(line) do
    case parse_endpoint(state.endpoint) do
      {:ok, host, port} ->
        expected =
          Enum.map_join(
            [state.endpoint, "http://#{host}:#{port}", state.token],
            ",",
            &csv_field/1
          )

        line |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim_trailing("\r") == expected

      :error ->
        false
    end
  end

  defp ready_output?(_line, _state), do: false

  defp csv_field(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp capture_output(diagnostics, line, token) when is_binary(line) do
    output =
      diagnostics.output_tail <>
        (line |> redact_output(token) |> String.replace_invalid()) <> "\n"

    offset = max(byte_size(output) - @output_tail_bytes, 0)

    %{
      diagnostics
      | output_tail:
          output
          |> binary_part(offset, byte_size(output) - offset)
          |> trim_utf8_prefix()
          |> :binary.copy(),
        database_locked?: diagnostics.database_locked? or database_lock_output?(line)
    }
  end

  defp capture_output(diagnostics, _line, _token), do: diagnostics

  # Truncating valid UTF-8 can leave up to three leading continuation bytes.
  defp trim_utf8_prefix(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: trim_utf8_prefix(rest)

  defp trim_utf8_prefix(value), do: value

  defp redact_output(line, token) do
    [token, String.replace(token, "'", "''"), String.replace(token, "\"", "\"\"")]
    |> Enum.flat_map(&String.split(&1, ["\n", "\r"], trim: true))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(line, &String.replace(&2, &1, "[REDACTED]"))
  end

  defp database_lock_output?(line) do
    String.contains?(line, ["Could not set lock on file", "Could not obtain lock on file"]) and
      String.contains?(line, [
        "Conflicting lock is held",
        "Resource temporarily unavailable",
        "another process"
      ])
  end

  defp startup_error(state, diagnostics, code, message) do
    {code, message} =
      if diagnostics.database_locked?,
        do: {:database_locked, "DuckDB database is locked by another process"},
        else: {code, message}

    QuackDB.Error.new(code, message,
      source: :client,
      metadata:
        diagnostics
        |> Map.delete(:database_locked?)
        |> Map.merge(%{uri: state.uri, database: state.database})
    )
  end

  defp check_ready(state) do
    with {:ok, uri} <- QuackDB.URI.normalize(state.uri),
         request <- connection_request(state),
         {:ok, response} <- QuackDB.Transport.post(uri, request, timeout: @ready_check_timeout),
         {:ok, {header, body}} <- Codec.decode(response),
         :ok <- ready_response(header, body) do
      disconnect(uri, header.connection_id)
      :ok
    end
  end

  defp connection_request(state) do
    %ConnectionRequest{
      auth_string: state.token,
      client_duckdb_version: "quackdb/server-check",
      client_platform: client_platform()
    }
    |> Codec.encode()
  end

  defp ready_response(_header, %ConnectionResponse{}), do: :ok

  defp ready_response(_header, %ErrorResponse{message: message}) do
    {:error, QuackDB.Error.new(:server_error, message, source: :server)}
  end

  defp ready_response(header, _body) do
    {:error,
     QuackDB.Error.new(:unexpected_message, "expected connection response, got #{header.type}",
       source: :protocol
     )}
  end

  defp disconnect(_uri, ""), do: :ok

  defp disconnect(uri, connection_id) do
    request = Codec.encode(%Disconnect{}, connection_id: connection_id)
    _ignored = QuackDB.Transport.post(uri, request, timeout: @ready_check_timeout)
    :ok
  end

  defp daemon_os_pid(nil), do: :error
  defp daemon_os_pid(pid), do: MuonTrap.Daemon.os_pid(pid)

  defp daemon_statistics(nil), do: %{}
  defp daemon_statistics(pid), do: MuonTrap.Daemon.statistics(pid)

  defp boot_sql(endpoint, token, options) do
    [
      attach_database(options),
      quack_extension_sql(options),
      server_settings(options),
      server_global_settings(options),
      QuackDB.SQL.call(:quack_serve, [endpoint], token: token)
    ]
    |> IO.iodata_to_binary()
  end

  defp quack_extension_sql(options) do
    if Keyword.get(options, :load_quack?, true) do
      install =
        if Keyword.get(options, :install_quack?, true),
          do: [QuackDB.SQL.install(:quack), " "],
          else: []

      [install, QuackDB.SQL.load(:quack), " "]
    else
      []
    end
  end

  defp attach_database(options) do
    case Keyword.fetch(options, :recovery_mode) do
      {:ok, recovery_mode} ->
        database = Keyword.get(options, :database, ":memory:")

        if database == ":memory:" do
          raise ArgumentError, "server option :recovery_mode requires a persistent :database path"
        end

        alias_name = Keyword.get(options, :attach_as, :quackdb)

        [
          "ATTACH ",
          QuackDB.SQL.literal!(database),
          " AS ",
          QuackDB.Type.quote_identifier(alias_name),
          " (RECOVERY_MODE ",
          recovery_mode(recovery_mode),
          "); USE ",
          QuackDB.Type.quote_identifier(alias_name),
          "; "
        ]

      :error ->
        []
    end
  end

  defp recovery_mode(:no_wal_writes), do: "no_wal_writes"
  defp recovery_mode(value) when is_binary(value), do: value

  defp server_settings(options) do
    options
    |> Keyword.get(:settings, default_settings())
    |> Enum.map(fn {name, value} -> [QuackDB.SQL.set(name, value), " "] end)
  end

  defp server_global_settings(options) do
    options
    |> Keyword.get(:global_settings, default_global_settings())
    |> Enum.map(fn {name, value} -> [QuackDB.SQL.set_global(name, value), " "] end)
  end

  defp default_settings do
    [threads: System.schedulers_online()]
  end

  defp default_global_settings do
    [quack_fetch_batch_chunks: 4]
  end

  defp default_uri(endpoint) do
    case parse_endpoint(endpoint) do
      {:ok, "localhost", port} -> "http://[::1]:#{port}"
      {:ok, host, port} -> "http://#{host}:#{port}"
      :error -> "http://[::1]:9494"
    end
  end

  defp parse_endpoint("quack:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [host] when host != "" -> {:ok, host, 9494}
      [host, port] when host != "" -> parse_port(host, port)
      _other -> :error
    end
  end

  defp parse_endpoint(_endpoint), do: :error

  defp parse_port(host, port) do
    case Integer.parse(port) do
      {port, ""} when port > 0 -> {:ok, host, port}
      _other -> :error
    end
  end

  defp random_token do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp client_platform do
    :system_architecture
    |> :erlang.system_info()
    |> List.to_string()
  end
end
