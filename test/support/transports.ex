defmodule QuackDB.TestTransports do
  @moduledoc false

  alias QuackDB.Protocol.Codec
  alias QuackDB.ProtocolFixtures
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.PrepareRequest

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
             result_uuid: 42
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
             result_uuid: 42
           )}

        {:ok, {%Header{type: :fetch_request}, _body}} ->
          {:ok, ProtocolFixtures.error_response(message)}
      end
    end
  end

  def connection_response do
    IO.iodata_to_binary([
      Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
      <<1::little-16, 5, "1.5.0">>,
      <<2::little-16, 6, "darwin">>,
      <<3::little-16, 1>>,
      <<0xFFFF::little-16>>
    ])
  end

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
