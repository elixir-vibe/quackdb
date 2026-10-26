defmodule QuackDB.Protocol.QuackTsConformanceTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Interval
  alias QuackDB.NanosecondTime
  alias QuackDB.NanosecondTimestamp
  alias QuackDB.ProtocolCrossFixtures
  alias QuackDB.TimeWithTimeZone

  @fixture_dir Path.expand("../../fixtures/quack_ts", __DIR__)

  for fixture <- ProtocolCrossFixtures.all() do
    @fixture_name fixture.name
    @fixture_file fixture.file
    @fixture_encoder fixture.encoder

    # quack-ts encodes strings in the pre-2.0 list layout, which DuckDB 2.0
    # still reads. QuackDB now writes the 2.0 layout, so these fixtures are
    # decode-compatibility checks rather than byte-for-byte encode parity.
    test "#{@fixture_name} fixture decodes to the same rows QuackDB encodes" do
      expected = apply(ProtocolCrossFixtures, @fixture_encoder, [])

      assert {:ok, %DataChunk{} = fixture_chunk, ""} =
               @fixture_file |> read_fixture!() |> DataChunk.decode_wrapper()

      assert {:ok, %DataChunk{} = encoded_chunk, ""} = DataChunk.decode_wrapper(expected)
      assert DataChunk.rows(fixture_chunk) == DataChunk.rows(encoded_chunk)
      assert fixture_chunk.types == encoded_chunk.types
    end
  end

  test "extra BIGNUM fixture decodes" do
    assert {:ok, %DataChunk{} = chunk, ""} =
             "data_chunk_bignum_extra.bin" |> read_fixture!() |> DataChunk.decode_wrapper()

    assert [
             [0],
             [123_456_789_012_345_678_901_234_567_890],
             [-123_456_789_012_345_678_901_234_567_890]
           ] = DataChunk.rows(chunk, ["bignum"])
  end

  test "extra temporal fixture decodes" do
    assert {:ok, %DataChunk{} = chunk, ""} =
             "data_chunk_temporal_extra.bin" |> read_fixture!() |> DataChunk.decode_wrapper()

    assert [
             [
               %NanosecondTime{nanoseconds: 1_234_567_890},
               %NanosecondTimestamp{nanoseconds: 1_770_000_000_123_456_789},
               %TimeWithTimeZone{},
               %Interval{months: 14, days: 3, microseconds: 987_654_321}
             ],
             [nil, nil, nil, nil]
           ] = DataChunk.rows(chunk, ["time_ns", "timestamp_ns", "time_tz", "interval"])
  end

  test "extra spatial fixture decodes" do
    assert {:ok, %DataChunk{} = chunk, ""} =
             "data_chunk_spatial_extra.bin" |> read_fixture!() |> DataChunk.decode_wrapper()

    assert [[<<1, 1, 0, 0, _rest::binary>>], [nil]] = DataChunk.rows(chunk, ["geom"])
  end

  test "extra nested null fixture decodes" do
    assert {:ok, %DataChunk{} = chunk, ""} =
             "data_chunk_nested_nulls_extra.bin" |> read_fixture!() |> DataChunk.decode_wrapper()

    assert [
             [nil, nil, nil],
             [[], %{"count" => 2, "name" => nil}, %{}],
             [[1, nil, 3], %{"count" => nil, "name" => "duck"}, %{"a" => 1, "b" => nil}]
           ] = DataChunk.rows(chunk, ["items", "metadata", "labels"])
  end

  defp read_fixture!(file) do
    @fixture_dir
    |> Path.join(file)
    |> File.read!()
  end
end
