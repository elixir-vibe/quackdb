defmodule QuackDB.Protocol.NonFiniteFloatTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Reader

  @doubles [
    {:infinity, <<0x7FF0_0000_0000_0000::little-unsigned-64>>},
    {:neg_infinity, <<0xFFF0_0000_0000_0000::little-unsigned-64>>},
    {:nan, <<0x7FF8_0000_0000_0000::little-unsigned-64>>},
    # A signalling NaN and a negative NaN are still NaN.
    {:nan, <<0x7FF0_0000_0000_0001::little-unsigned-64>>},
    {:nan, <<0xFFF8_0000_0000_0000::little-unsigned-64>>}
  ]

  @floats [
    {:infinity, <<0x7F80_0000::little-unsigned-32>>},
    {:neg_infinity, <<0xFF80_0000::little-unsigned-32>>},
    {:nan, <<0x7FC0_0000::little-unsigned-32>>},
    {:nan, <<0xFF80_0001::little-unsigned-32>>}
  ]

  test "reads the IEEE non-finite doubles as atoms, and finite ones as floats" do
    for {atom, bytes} <- @doubles do
      assert {:ok, ^atom, "rest"} = Reader.read_float64(bytes <> "rest")
    end

    assert {:ok, 1.5, ""} = Reader.read_float64(<<1.5::little-float-64>>)

    assert {:ok, 1.7976931348623157e308, ""} =
             Reader.read_float64(<<1.7976931348623157e308::little-float-64>>)

    assert {:error, %QuackDB.Error{code: :truncated_float64}} = Reader.read_float64(<<1, 2, 3>>)
  end

  test "reads the IEEE non-finite floats as atoms" do
    for {atom, bytes} <- @floats do
      assert {:ok, ^atom, ""} = Reader.read_float32(bytes)
    end

    assert {:ok, 2.5, ""} = Reader.read_float32(<<2.5::little-float-32>>)
    assert {:error, %QuackDB.Error{code: :truncated_float32}} = Reader.read_float32(<<1>>)
  end

  test "formats the atoms as DuckDB's non-finite double literals" do
    assert {:ok, "'inf'::DOUBLE"} = QuackDB.SQL.literal(:infinity)
    assert {:ok, "'-inf'::DOUBLE"} = QuackDB.SQL.literal(:neg_infinity)
    assert {:ok, "'nan'::DOUBLE"} = QuackDB.SQL.literal(:nan)

    assert {:ok, iodata} = QuackDB.SQL.literal([:infinity, 1.5])
    assert IO.iodata_to_binary(iodata) == "['inf'::DOUBLE, 1.5]"
  end
end
