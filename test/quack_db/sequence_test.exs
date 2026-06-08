defmodule QuackDB.SequenceTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header

  test "next_values queries nextval over range" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([123, 124, 125])

    transport = fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, QuackDB.TestTransports.connection_response()}

        {:ok, {%Header{type: :prepare_request}, query}} ->
          send(parent, {:statement, query.sql_query})
          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [chunk], names: ["value"])}
      end
    end

    conn =
      start_supervised!(
        {QuackDB, uri: "http://localhost:9494", token: "secret", transport: transport}
      )

    assert QuackDB.Sequence.next_values(conn, "frag'ments_id_seq", 3) == [123, 124, 125]

    assert_receive {:statement, "SELECT nextval('frag''ments_id_seq') AS value FROM range(3)"}
  end

  test "next_values validates count" do
    assert_raise ArgumentError, ~r/non-negative count/, fn ->
      QuackDB.Sequence.next_values(self(), "events_id_seq", -1)
    end
  end
end
