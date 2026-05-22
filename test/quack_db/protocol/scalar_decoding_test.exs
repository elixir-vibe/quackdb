defmodule QuackDB.Protocol.ScalarDecodingTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.DataChunk

  test "decodes common scalar columns into Elixir values" do
    binary =
      QuackDB.ProtocolFixtures.scalar_chunk_wrapper([
        {:boolean, :bool, [true, false, nil]},
        {:bigint, :int64, [1, -2, 3]},
        {:double, :double, [1.5, -2.25, 0.0]},
        {:varchar, :varchar, ["duck", nil, "quack"]},
        {:blob, :varchar, [<<1, 2>>, <<>>, nil]},
        {:date, :int32, [0, 1, -1]},
        {:timestamp, :int64, [0, 1_000_000, -1_000_000]},
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
               ~N[1970-01-01 00:00:00.000000],
               Decimal.new(1, 12345, -2)
             ],
             [
               false,
               -2,
               -2.25,
               nil,
               <<>>,
               ~D[1970-01-02],
               ~N[1970-01-01 00:00:01.000000],
               Decimal.new(-1, 500, -2)
             ],
             [
               nil,
               3,
               0.0,
               "quack",
               nil,
               ~D[1969-12-31],
               ~N[1969-12-31 23:59:59.000000],
               Decimal.new(1, 0, -2)
             ]
           ]
  end
end
