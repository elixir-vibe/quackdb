defmodule QuackDB.Protocol.ScalarDecodingTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.DataChunk

  test "rejects BIGNUM payloads whose declared magnitude size is truncated" do
    assert_raise QuackDB.Error, ~r/BIGNUM payload size does not match header/, fn ->
      "data_chunk_bignum_bad_size.bin"
      |> malformed_fixture!()
      |> DataChunk.decode_wrapper()
    end
  end

  test "rejects data chunks whose logical types outnumber vectors" do
    assert {:error,
            %QuackDB.Error{
              code: :data_chunk_type_mismatch,
              message: "data chunk has 1 types and 0 columns"
            }} =
             "data_chunk_missing_vector.bin"
             |> malformed_fixture!()
             |> DataChunk.decode_wrapper()
  end

  test "decodes common scalar columns into Elixir values" do
    binary =
      QuackDB.ProtocolFixtures.scalar_chunk_wrapper([
        {:boolean, :bool, [true, false, nil]},
        {:bigint, :int64, [1, -2, 3]},
        {:double, :double, [1.5, -2.25, 0.0]},
        {:varchar, :varchar, ["duck", nil, "quack"]},
        {:blob, :varchar, [<<1, 2>>, <<>>, nil]},
        {:date, :int32, [0, 1, -1]},
        {:time_ns, :int64, [1_234_567_890, 0, 42]},
        {:time_tz, :int64, [16_777_216_057_599, 16_777_216_053_999, 16_777_216_061_199]},
        {:timestamp, :int64, [0, 1_000_000, -1_000_000]},
        {:timestamp_ns, :int64, [1_234_567_890, 0, -1_234_567_890]},
        {:interval, :interval, [{1, 2, 3}, {0, 1, 1000}, nil]},
        {:bignum, :varchar, [<<128, 0, 1, 1>>, <<127, 255, 254, 254>>, <<128, 0, 2, 1, 0>>]},
        {:decimal, :int64, [12345, -500, 0]}
      ])
      |> IO.iodata_to_binary()

    assert {:ok, chunk, ""} = DataChunk.decode_wrapper(binary)

    assert DataChunk.rows(chunk) == [
             [
               true,
               1,
               1.5,
               "duck",
               <<1, 2>>,
               ~D[1970-01-01],
               QuackDB.NanosecondTime.new(1_234_567_890),
               QuackDB.TimeWithTimeZone.new(~T[00:00:01.000000], 0),
               ~N[1970-01-01 00:00:00.000000],
               QuackDB.NanosecondTimestamp.new(1_234_567_890),
               QuackDB.Interval.new(1, 2, 3),
               1,
               Decimal.new(1, 12345, -2)
             ],
             [
               false,
               -2,
               -2.25,
               nil,
               <<>>,
               ~D[1970-01-02],
               QuackDB.NanosecondTime.new(0),
               QuackDB.TimeWithTimeZone.new(~T[00:00:01.000000], 3600),
               ~N[1970-01-01 00:00:01.000000],
               QuackDB.NanosecondTimestamp.new(0),
               QuackDB.Interval.new(0, 1, 1000),
               -1,
               Decimal.new(-1, 500, -2)
             ],
             [
               nil,
               3,
               0.0,
               "quack",
               nil,
               ~D[1969-12-31],
               QuackDB.NanosecondTime.new(42),
               QuackDB.TimeWithTimeZone.new(~T[00:00:01.000000], -3600),
               ~N[1969-12-31 23:59:59.000000],
               QuackDB.NanosecondTimestamp.new(-1_234_567_890),
               nil,
               256,
               Decimal.new(1, 0, -2)
             ]
           ]
  end

  defp malformed_fixture!(name) do
    Path.join(["test", "fixtures", "quackdb_malformed", name])
    |> File.read!()
  end
end
