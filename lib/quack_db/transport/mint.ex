defmodule QuackDB.Transport.Mint do
  @moduledoc """
  Mint-backed stateful HTTP transport for Quack binary requests.
  """

  use GenServer

  alias QuackDB.Error

  @headers [
    {"content-type", "application/duckdb"},
    {"accept", "application/duckdb, application/vnd.duckdb, application/octet-stream"}
  ]
  @default_timeout 15_000
  @call_timeout_buffer 1_000

  @type option ::
          {:timeout, timeout()}
          | {:connect_timeout, timeout()}
          | {:receive_timeout, timeout()}
          | {:shutdown_timeout, timeout()}
          | {:mint_options, keyword()}

  def start_link(uri, options \\ []) do
    GenServer.start_link(__MODULE__, {uri, options})
  end

  def post(server, _uri, body, options \\ []) do
    timeout = call_timeout(options)

    GenServer.call(
      server,
      {:post, IO.iodata_to_binary(body), options},
      call_timeout_with_buffer(timeout)
    )
  end

  @impl true
  def init({uri, options}) do
    {:ok, %{uri: uri, options: options, conn: nil}}
  end

  @impl true
  def handle_call({:post, body, options}, _from, state) do
    timeout = receive_timeout(options)

    case ensure_connection(state, connect_timeout(options, timeout)) do
      {:ok, state} ->
        path = request_path(state.uri)

        case Mint.HTTP.request(state.conn, "POST", path, @headers, body) do
          {:ok, conn, request_ref} ->
            state = %{state | conn: conn}

            case recv_response(state, request_ref, timeout, nil, []) do
              {:ok, response, state} -> {:reply, {:ok, response}, state}
              {:error, error, state} -> {:reply, {:error, error}, state}
            end

          {:error, conn, reason} ->
            {:reply, {:error, mint_error(reason)}, %{state | conn: conn}}
        end

      {:error, error, state} ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_info(message, state) do
    case stream_message(state, message) do
      :unknown -> {:noreply, state}
      {:ok, state, _responses} -> {:noreply, state}
      {:error, _error, state} -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn, options: options}) do
    if conn do
      _ = Mint.HTTP.close(conn)
      Process.sleep(Keyword.get(options, :shutdown_timeout, 0))
    end

    :ok
  end

  defp ensure_connection(%{conn: nil} = state, timeout), do: connect(state, timeout)

  defp ensure_connection(%{conn: conn} = state, timeout) do
    if Mint.HTTP.open?(conn) do
      {:ok, state}
    else
      connect(%{state | conn: nil}, timeout)
    end
  end

  defp connect(%{uri: uri, options: options} = state, timeout) do
    scheme = scheme(uri)
    port = uri.port || default_port(scheme)
    {address, mint_options} = connect_address(uri, options, timeout)

    case Mint.HTTP.connect(scheme, address, port, mint_options) do
      {:ok, conn} -> {:ok, %{state | conn: conn}}
      {:error, reason} -> {:error, mint_error(reason), %{state | conn: nil}}
    end
  end

  defp recv_response(state, request_ref, timeout, status, chunks) do
    receive do
      message ->
        case stream_message(state, message) do
          {:ok, state, responses} ->
            handle_responses(responses, state, request_ref, timeout, status, chunks)

          {:error, error, state} ->
            {:error, error, state}

          :unknown ->
            recv_response(state, request_ref, timeout, status, chunks)
        end
    after
      timeout ->
        {:error, Error.new(:transport_error, "HTTP response timed out", source: :transport),
         close_connection(state)}
    end
  end

  defp handle_responses([], state, request_ref, timeout, status, chunks) do
    recv_response(state, request_ref, timeout, status, chunks)
  end

  defp handle_responses(
         [{:status, request_ref, status} | rest],
         state,
         request_ref,
         timeout,
         _status,
         chunks
       ) do
    handle_responses(rest, state, request_ref, timeout, status, chunks)
  end

  defp handle_responses(
         [{:headers, request_ref, _headers} | rest],
         state,
         request_ref,
         timeout,
         status,
         chunks
       ) do
    handle_responses(rest, state, request_ref, timeout, status, chunks)
  end

  defp handle_responses(
         [{:data, request_ref, data} | rest],
         state,
         request_ref,
         timeout,
         status,
         chunks
       ) do
    handle_responses(rest, state, request_ref, timeout, status, [data | chunks])
  end

  defp handle_responses([{:done, request_ref} | _rest], state, request_ref, _timeout, 200, chunks) do
    {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  defp handle_responses(
         [{:done, request_ref} | _rest],
         state,
         request_ref,
         _timeout,
         status,
         chunks
       ) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    message = "Quack server returned HTTP #{inspect(status)}"

    {:error,
     Error.new(:http_error, message, source: :transport, metadata: %{body: body, status: status}),
     state}
  end

  defp handle_responses([_other | rest], state, request_ref, timeout, status, chunks) do
    handle_responses(rest, state, request_ref, timeout, status, chunks)
  end

  defp stream_message(%{conn: nil}, _message), do: :unknown

  defp stream_message(%{conn: conn} = state, message) do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, responses} ->
        {:ok, %{state | conn: conn}, responses}

      {:error, conn, reason, _responses} ->
        {:error, mint_error(reason), close_if_closed(%{state | conn: conn})}

      :unknown ->
        :unknown
    end
  end

  defp request_path(%URI{path: nil, query: nil}), do: "/"
  defp request_path(%URI{path: "", query: nil}), do: "/"
  defp request_path(%URI{path: nil, query: query}), do: "/?" <> query
  defp request_path(%URI{path: "", query: query}), do: "/?" <> query
  defp request_path(%URI{path: path, query: nil}), do: path
  defp request_path(%URI{path: path, query: query}), do: path <> "?" <> query

  defp scheme(%URI{scheme: "http"}), do: :http
  defp scheme(%URI{scheme: "https"}), do: :https

  defp call_timeout(options), do: Keyword.get(options, :timeout, @default_timeout)

  defp call_timeout_with_buffer(:infinity), do: :infinity
  defp call_timeout_with_buffer(timeout), do: timeout + @call_timeout_buffer

  defp connect_timeout(options, fallback), do: Keyword.get(options, :connect_timeout, fallback)

  defp receive_timeout(options), do: Keyword.get(options, :receive_timeout, call_timeout(options))

  defp connect_address(%URI{host: host}, options, timeout) do
    mint_options =
      options
      |> Keyword.get(:mint_options, [])
      |> Keyword.put_new(:protocols, [:http1])
      |> Keyword.update(
        :transport_opts,
        [timeout: timeout],
        &Keyword.put_new(&1, :timeout, timeout)
      )

    case :inet.parse_address(to_charlist(host)) do
      {:ok, address} -> {address, Keyword.put_new(mint_options, :hostname, host)}
      {:error, _reason} -> {host, mint_options}
    end
  end

  defp close_connection(%{conn: nil} = state), do: state

  defp close_connection(%{conn: conn} = state) do
    _ = Mint.HTTP.close(conn)
    %{state | conn: nil}
  end

  defp close_if_closed(%{conn: nil} = state), do: state

  defp close_if_closed(%{conn: conn} = state) do
    if Mint.HTTP.open?(conn), do: state, else: %{state | conn: nil}
  end

  defp default_port(:http), do: 80
  defp default_port(:https), do: 443

  defp mint_error(reason) do
    Error.new(:transport_error, Exception.message(reason),
      source: :transport,
      metadata: %{reason: reason}
    )
  end
end
