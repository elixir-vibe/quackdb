defmodule QuackDB.Connection do
  @moduledoc false

  use GenServer

  alias QuackDB.Error
  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.Disconnect
  alias QuackDB.Protocol.Message.ErrorResponse
  alias QuackDB.Protocol.Message.PrepareRequest

  defstruct [:uri, :token, :connection_id, :server, :transport, :client_version]

  @type transport :: (URI.t(), iodata(), Keyword.t() -> {:ok, binary()} | {:error, Error.t()})

  @type option ::
          {:uri, String.t()}
          | {:token, String.t()}
          | {:name, GenServer.name()}
          | {:connect, boolean()}
          | {:transport, transport()}
          | {:client_version, String.t()}

  @spec start_link([option]) :: GenServer.on_start()
  def start_link(options) do
    {gen_server_options, connection_options} = Keyword.split(options, [:name])
    GenServer.start_link(__MODULE__, connection_options, gen_server_options)
  end

  @spec query(GenServer.server(), iodata(), [term()], Keyword.t()) ::
          {:ok, QuackDB.Result.t()} | {:error, Error.t()}
  def query(connection, statement, params \\ [], options \\ []) do
    GenServer.call(
      connection,
      {:query, statement, params, options},
      Keyword.get(options, :timeout, 15_000)
    )
  end

  @impl true
  def init(options) do
    with {:ok, state} <- build_state(options) do
      if Keyword.get(options, :connect, true) do
        connect(state)
      else
        {:ok, state}
      end
    else
      {:error, error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call({:query, _statement, params, _options}, _from, state) when params != [] do
    error = Error.new(:parameters_not_supported, "Quack does not expose bind parameters yet")
    {:reply, {:error, error}, state}
  end

  def handle_call({:query, _statement, _params, _options}, _from, %{connection_id: nil} = state) do
    error = Error.new(:not_connected, "Quack connection has not completed the handshake")
    {:reply, {:error, error}, state}
  end

  def handle_call({:query, statement, _params, options}, _from, state) do
    message = %PrepareRequest{sql_query: IO.iodata_to_binary(statement)}
    request = Codec.encode(message, connection_id: state.connection_id)

    reply =
      with {:ok, response} <- state.transport.(state.uri, request, options),
           {:ok, decoded} <- Codec.decode(response) do
        normalize_query_response(decoded)
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, %{connection_id: nil}), do: :ok

  def terminate(_reason, state) do
    request = Codec.encode(%Disconnect{}, connection_id: state.connection_id)
    _ignored = state.transport.(state.uri, request, timeout: 1_000)
    :ok
  end

  defp build_state(options) do
    uri = Keyword.get(options, :uri, "http://localhost:9494")

    with {:ok, uri} <- QuackDB.URI.normalize(uri) do
      {:ok,
       %__MODULE__{
         uri: uri,
         token: Keyword.get(options, :token, ""),
         transport: Keyword.get(options, :transport, &QuackDB.Transport.post/3),
         client_version: Keyword.get(options, :client_version, client_version())
       }}
    end
  end

  defp connect(state) do
    request =
      %ConnectionRequest{
        auth_string: state.token,
        client_duckdb_version: state.client_version,
        client_platform: client_platform()
      }
      |> Codec.encode()

    with {:ok, response} <- state.transport.(state.uri, request, []),
         {:ok, decoded} <- Codec.decode(response),
         {:ok, state} <- normalize_connect_response(decoded, state) do
      {:ok, state}
    else
      {:error, error} -> {:stop, error}
    end
  end

  defp normalize_connect_response({header, %ConnectionResponse{} = response}, state) do
    {:ok, %{state | connection_id: header.connection_id, server: response}}
  end

  defp normalize_connect_response({_header, %ErrorResponse{message: message}}, _state) do
    {:error, Error.new(:server_error, message, source: :server)}
  end

  defp normalize_connect_response({header, _body}, _state) do
    message = "expected connection response, got #{header.type}"
    {:error, Error.new(:unexpected_message, message, source: :protocol)}
  end

  defp normalize_query_response({_header, %ErrorResponse{message: message}}) do
    {:error, Error.new(:server_error, message, source: :server)}
  end

  defp normalize_query_response({header, _body}) do
    message = "decoding #{header.type} query responses is not implemented yet"
    {:error, Error.new(:not_implemented, message, source: :protocol)}
  end

  defp client_version do
    case Application.spec(:quackdb, :vsn) do
      nil -> "quackdb/dev"
      version -> "quackdb/#{version}"
    end
  end

  defp client_platform do
    :system_architecture
    |> :erlang.system_info()
    |> List.to_string()
  end
end
