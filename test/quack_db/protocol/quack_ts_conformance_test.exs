defmodule QuackDB.Protocol.QuackTsConformanceTest do
  use ExUnit.Case, async: true

  import QuackDB.ProtocolAssertions

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.Message.AppendRequest
  alias QuackDB.ProtocolCrossFixtures

  @fixture_dir Path.expand("../../fixtures/quack_ts", __DIR__)

  for fixture <- ProtocolCrossFixtures.all() do
    @fixture_name fixture.name
    @fixture_file fixture.file
    @fixture_encoder fixture.encoder

    test "#{@fixture_name} encoding matches quack-ts" do
      actual = apply(ProtocolCrossFixtures, @fixture_encoder, [])

      assert_same_binary(actual, read_fixture!(@fixture_file))
    end

    test "#{@fixture_name} fixture decodes and re-encodes" do
      fixture = read_fixture!(@fixture_file)
      expected = apply(ProtocolCrossFixtures, @fixture_encoder, [])

      assert_decodable_fixture(@fixture_file, fixture, expected)
    end
  end

  defp assert_decodable_fixture("data_chunk_nested.bin", fixture, _expected) do
    assert {:ok, %DataChunk{row_count: 2} = chunk, ""} = DataChunk.decode_wrapper(fixture)
    assert DataChunk.rows(chunk, ["id", "tags", "metadata", "scores", "labels"])
  end

  defp assert_decodable_fixture("append_request_nested.bin", fixture, _expected) do
    assert {:ok, {_header, %AppendRequest{append_chunk: %DataChunk{row_count: 2}}}} =
             Codec.decode(fixture)
  end

  defp assert_decodable_fixture("data_chunk_" <> _rest, fixture, expected) do
    assert {:ok, %DataChunk{} = chunk, ""} = DataChunk.decode_wrapper(fixture)
    actual = chunk |> DataChunk.encode_wrapper() |> IO.iodata_to_binary()
    assert_same_binary(actual, expected)
  end

  defp assert_decodable_fixture("append_request_" <> _rest, fixture, expected) do
    assert {:ok, {_header, %AppendRequest{} = message}} = Codec.decode(fixture)
    actual = message |> Codec.encode(connection_id: "conn-1") |> IO.iodata_to_binary()
    assert_same_binary(actual, expected)
  end

  defp read_fixture!(file) do
    @fixture_dir
    |> Path.join(file)
    |> File.read!()
  end
end
