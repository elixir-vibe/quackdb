defmodule QuackDB.TestTransports do
  @moduledoc false

  alias QuackDB.Protocol.Codec
  alias QuackDB.ProtocolFixtures
  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.Message.CancelRequest
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.FetchRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.PrepareRequest
  alias QuackDB.Protocol.Message.PrepareResponse
  alias QuackDB.Protocol.Message.SendDataRequest
  alias QuackDB.Protocol.Message.SendDataResponse
  alias QuackDB.Protocol.Message.SuccessResponse

  def transport(options) do
    parent = Keyword.get(options, :parent)
    prepare_chunks = Keyword.fetch!(options, :prepare)
    names = Keyword.get(options, :names, ["n"])

    fn _uri, request, _request_options ->
      request
      |> IO.iodata_to_binary()
      |> decode_request(parent)
      |> case do
        :connection ->
          {:ok, connection_response()}

        {:prepare, _statement} ->
          {:ok, ProtocolFixtures.prepare_response(chunks: prepare_chunks, names: names)}
      end
    end
  end

  def transport_error(message) do
    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
          {:ok, ProtocolFixtures.error_response(message)}
      end
    end
  end

  def stream_transport(initial_chunk, fetched_chunk, options \\ []) do
    {:ok, fetch_agent} = Agent.start_link(fn -> 0 end)
    parent = Keyword.get(options, :parent)

    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}}
        when statement in ["BEGIN", "COMMIT", "ROLLBACK"] ->
          {:ok, ProtocolFixtures.prepare_response(chunks: [])}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
          {:ok,
           ProtocolFixtures.prepare_response(
             chunks: [initial_chunk],
             needs_more_fetch?: true,
             query_uuid: 42
           )}

        {:ok, {%Header{type: :fetch_request}, _body}} ->
          fetch_count = Agent.get_and_update(fetch_agent, &{&1, &1 + 1})
          if parent, do: send(parent, {:fetch, fetch_count})
          chunks = if fetch_count == 0, do: [fetched_chunk], else: []
          {:ok, ProtocolFixtures.fetch_response(chunks, batch_index: fetch_count)}
      end
    end
  end

  def stream_error_transport(initial_chunk, message) do
    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}}
        when statement in ["BEGIN", "COMMIT", "ROLLBACK"] ->
          {:ok, ProtocolFixtures.prepare_response(chunks: [])}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
          {:ok,
           ProtocolFixtures.prepare_response(
             chunks: [initial_chunk],
             needs_more_fetch?: true,
             query_uuid: 42
           )}

        {:ok, {%Header{type: :fetch_request}, _body}} ->
          {:ok, ProtocolFixtures.error_response(message)}
      end
    end
  end

  def connection_response do
    IO.iodata_to_binary([
      Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
      <<1::little-16, 6, "v2.0.0">>,
      <<2::little-16, 6, "darwin">>,
      <<3::little-16, 3>>,
      <<4::little-16, 60>>,
      <<0xFFFF::little-16>>
    ])
  end

  @doc """
  A fake Quack server for native appends. It reports each SQL statement as
  `{:statement, sql}` and each send-data batch as `{:send_data, request}`, then
  answers the streaming INSERT with the row count it received, or with
  `:returning_rows` when given.

  Other prepare requests get an empty result.
  """
  def append_transport(parent, options \\ []) do
    {:ok, agent} = Agent.start_link(fn -> %{rows: 0, fetched?: false} end)

    fn _uri, request, _request_options ->
      case request |> IO.iodata_to_binary() |> Codec.decode() do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {_header, %PrepareRequest{sql_query: sql, query_uuid: uuid, inline_rows: 0}}} ->
          send(parent, {:statement, sql})
          Agent.update(agent, fn _state -> %{rows: 0, fetched?: false} end)

          {:ok, encode(%PrepareResponse{needs_more_fetch: true, query_uuid: uuid, results: []})}

        {:ok, {_header, %PrepareRequest{sql_query: sql}}} ->
          send(parent, {:statement, sql})
          {:ok, ProtocolFixtures.prepare_response(chunks: [])}

        {:ok, {_header, %SendDataRequest{} = send_data}} ->
          send(parent, {:send_data, send_data})
          rows = Enum.reduce(send_data.chunks, 0, &(&1.row_count + &2))
          Agent.update(agent, &%{&1 | rows: &1.rows + rows})
          {:ok, encode(%SendDataResponse{})}

        {:ok, {_header, %FetchRequest{batch_index: 1}}} ->
          rows = Agent.get(agent, & &1.rows)
          {:ok, chunk} = append_result_chunk(rows, Keyword.get(options, :returning_rows))
          {:ok, encode(%QuackDB.Protocol.Message.FetchResponse{results: [chunk], batch_index: 1})}

        {:ok, {_header, %FetchRequest{}}} ->
          {:ok, encode(%QuackDB.Protocol.Message.FetchResponse{total_batches: 1})}

        {:ok, {_header, %CancelRequest{}}} ->
          send(parent, :cancel)
          {:ok, encode(%SuccessResponse{})}
      end
    end
  end

  defp append_result_chunk(rows, nil),
    do: DataChunk.from_rows([[Count: rows]], columns: [Count: :bigint])

  defp append_result_chunk(_rows, returning_rows), do: DataChunk.from_rows(returning_rows)

  defp encode(message),
    do: message |> Codec.encode(connection_id: "conn-1") |> IO.iodata_to_binary()

  defp decode_request(request, parent) do
    case Codec.decode(request) do
      {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
        :connection

      {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}} ->
        if parent, do: send(parent, {:statement, statement})
        {:prepare, statement}
    end
  end
end
