defmodule QuackDB.Server do
  @moduledoc """
  Supervises a local DuckDB Quack server process with MuonTrap.

  This is a convenience for local development, tests, demos, and notebooks. It
  starts the external `duckdb` executable and serves DuckDB's Quack HTTP
  protocol. It is not an embedded DuckDB driver and is not required when your
  Quack server runs elsewhere.

      children = [
        {QuackDB.Server, name: MyApp.DuckDB, token: "super_secret"},
        {QuackDB, name: MyApp.QuackDB, uri: "http://[::1]:9494", token: "super_secret"}
      ]

  By default the server runs DuckDB directly under MuonTrap with `-interactive`
  so the process stays alive after `quack_serve/2` starts:

      duckdb :memory: -interactive -init /dev/null -cmd "LOAD quack; ..."

  """

  use GenServer

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.Disconnect
  alias QuackDB.Protocol.Message.ErrorResponse

  defstruct [
    :daemon,
    :duckdb,
    :database,
    :endpoint,
    :uri,
    :token,
    :boot_sql,
    :daemon_command,
    :daemon_args,
    :daemon_options
  ]

  @type option ::
          {:name, GenServer.name()}
          | {:duckdb, String.t()}
          | {:database, String.t()}
          | {:endpoint, String.t()}
          | {:uri, String.t()}
          | {:token, String.t()}
          | {:load_quack?, boolean()}
          | {:boot_sql, String.t()}
          | {:wait, boolean()}
          | {:wait_timeout, timeout()}
          | {:poll_interval, pos_integer()}
          | {:daemon_options, Keyword.t()}
          | {:daemon_command, {String.t(), [String.t()]}}

  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(options \\ []) do
    server_options = Keyword.get(options, :server, [])
    client_options = Keyword.get(options, :client, [])
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

    [child_spec(server_options), QuackDB.child_spec(client_options)]
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

  @spec os_pid(GenServer.server()) :: non_neg_integer() | :error
  def os_pid(server), do: GenServer.call(server, :os_pid)

  @spec statistics(GenServer.server()) :: map()
  def statistics(server), do: GenServer.call(server, :statistics)

  @impl true
  def init(options) do
    state = build_state(options)

    with {:ok, daemon} <- start_daemon(state) do
      state = %{state | daemon: daemon}

      if Keyword.get(options, :wait, true) do
        wait_ready!(
          state,
          Keyword.get(options, :wait_timeout, 5_000),
          Keyword.get(options, :poll_interval, 100)
        )
      end

      {:ok, state}
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
      os_pid: daemon_os_pid(state.daemon),
      statistics: daemon_statistics(state.daemon)
    }

    {:reply, info, state}
  end

  def handle_call(:os_pid, _from, state), do: {:reply, daemon_os_pid(state.daemon), state}
  def handle_call(:statistics, _from, state), do: {:reply, daemon_statistics(state.daemon), state}

  @impl true
  def terminate(_reason, %{daemon: daemon}) when is_pid(daemon) do
    Process.exit(daemon, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp build_state(options) do
    duckdb = Keyword.get(options, :duckdb, "duckdb")
    database = Keyword.get(options, :database, ":memory:")
    endpoint = Keyword.get(options, :endpoint, "quack:localhost")
    uri = Keyword.get(options, :uri, default_uri(endpoint))
    token = Keyword.get_lazy(options, :token, &random_token/0)
    boot_sql = Keyword.get_lazy(options, :boot_sql, fn -> boot_sql(endpoint, token, options) end)
    daemon_options = daemon_options(options)

    {command, args} =
      Keyword.get_lazy(options, :daemon_command, fn ->
        daemon_command(duckdb, database, boot_sql)
      end)

    %__MODULE__{
      duckdb: duckdb,
      database: database,
      endpoint: endpoint,
      uri: uri,
      token: token,
      boot_sql: boot_sql,
      daemon_command: command,
      daemon_args: args,
      daemon_options: daemon_options
    }
  end

  defp daemon_options(options) do
    options
    |> Keyword.get(:daemon_options, [])
    |> Keyword.put_new(:stderr_to_stdout, true)
    |> Keyword.put_new(:log_prefix, "[quackdb-server] ")
  end

  defp daemon_command(duckdb, database, boot_sql) do
    {duckdb, [database, "-interactive", "-init", "/dev/null", "-cmd", boot_sql]}
  end

  defp start_daemon(state) do
    MuonTrap.Daemon.start_link(state.daemon_command, state.daemon_args, state.daemon_options)
  end

  defp wait_ready!(state, timeout, poll_interval) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_ready!(state, deadline, poll_interval, nil)
  end

  defp do_wait_ready!(state, deadline, poll_interval, last_error) do
    case check_ready(state) do
      :ok ->
        :ok

      {:error, error} ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise QuackDB.Error.new(
                  :server_start_timeout,
                  "DuckDB Quack server did not become ready",
                  source: :client,
                  metadata: %{last_error: error, uri: state.uri}
                )
        else
          Process.sleep(poll_interval)
          do_wait_ready!(state, deadline, poll_interval, error || last_error)
        end
    end
  end

  defp check_ready(state) do
    with {:ok, uri} <- QuackDB.URI.normalize(state.uri),
         request <- connection_request(state),
         {:ok, response} <- QuackDB.Transport.post(uri, request, timeout: 1_000),
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

  defp disconnect(_uri, nil), do: :ok
  defp disconnect(_uri, ""), do: :ok

  defp disconnect(uri, connection_id) do
    request = Codec.encode(%Disconnect{}, connection_id: connection_id)
    _ignored = QuackDB.Transport.post(uri, request, timeout: 1_000)
    :ok
  end

  defp daemon_os_pid(nil), do: :error
  defp daemon_os_pid(pid), do: MuonTrap.Daemon.os_pid(pid)

  defp daemon_statistics(nil), do: %{}
  defp daemon_statistics(pid), do: MuonTrap.Daemon.statistics(pid)

  defp boot_sql(endpoint, token, options) do
    [
      if(Keyword.get(options, :load_quack?, true), do: [QuackDB.SQL.load(:quack), " "], else: []),
      QuackDB.SQL.call(:quack_serve, [endpoint], token: token)
    ]
    |> IO.iodata_to_binary()
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
