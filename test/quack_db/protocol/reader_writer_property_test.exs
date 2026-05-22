defmodule QuackDB.Protocol.ReaderWriterPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias QuackDB.Protocol.Reader
  alias QuackDB.Protocol.Writer

  property "ULEB128 roundtrips non-negative integers" do
    check all(value <- integer(0..0xFFFF_FFFF_FFFF_FFFF)) do
      encoded = IO.iodata_to_binary(Writer.uleb128(value))
      assert {:ok, ^value, ""} = Reader.read_uleb128(encoded)
    end
  end

  property "SLEB128 roundtrips signed integers" do
    check all(value <- integer(-(1 <<< 127)..((1 <<< 127) - 1))) do
      encoded = IO.iodata_to_binary(Writer.sleb128(value))
      assert {:ok, ^value, ""} = Reader.read_sleb128(encoded)
    end
  end

  property "hugeint roundtrips signed 128-bit integers" do
    check all(value <- integer(-(1 <<< 127)..((1 <<< 127) - 1))) do
      encoded = IO.iodata_to_binary(Writer.hugeint(value))
      assert {:ok, ^value, ""} = Reader.read_hugeint(encoded)
    end
  end

  property "blob roundtrips arbitrary binaries" do
    check all(value <- binary()) do
      encoded = IO.iodata_to_binary(Writer.blob(value))
      assert {:ok, ^value, ""} = Reader.read_blob(encoded)
    end
  end

  property "string roundtrips valid strings" do
    check all(value <- string(:printable)) do
      encoded = IO.iodata_to_binary(Writer.string(value))
      assert {:ok, ^value, ""} = Reader.read_string(encoded)
    end
  end

  property "lists roundtrip through element codecs" do
    check all(values <- list_of(integer(0..10_000), max_length: 100)) do
      encoded = IO.iodata_to_binary(Writer.list(values, &Writer.uleb128/1))
      assert {:ok, ^values, ""} = Reader.read_list(encoded, &Reader.read_uleb128/1)
    end
  end

  property "nullable values roundtrip" do
    check all(value <- one_of([constant(nil), integer(0..10_000)])) do
      encoded = IO.iodata_to_binary(Writer.nullable(value, &Writer.uleb128/1))
      assert {:ok, ^value, ""} = Reader.read_nullable(encoded, &Reader.read_uleb128/1)
    end
  end

  property "optional indexes roundtrip" do
    check all(value <- one_of([constant(nil), integer(0..0xFFFF_FFFF)])) do
      encoded = IO.iodata_to_binary(Writer.optional_index(value))
      assert {:ok, ^value, ""} = Reader.read_optional_index(encoded)
    end
  end

  test "truncated primitive inputs return protocol errors" do
    assert {:error, %QuackDB.Error{code: :truncated_field_id}} = Reader.read_field_id(<<1>>)
    assert {:error, %QuackDB.Error{code: :truncated_bool}} = Reader.read_bool(<<>>)
    assert {:error, %QuackDB.Error{code: :truncated_uleb128}} = Reader.read_uleb128(<<0x80>>)
    assert {:error, %QuackDB.Error{code: :truncated_sleb128}} = Reader.read_sleb128(<<0x80>>)
    assert {:error, %QuackDB.Error{code: :truncated_binary}} = Reader.read_blob(<<5, "abc">>)
  end

  test "invalid string input returns protocol error" do
    encoded = IO.iodata_to_binary(Writer.blob(<<0xFF>>))
    assert {:error, %QuackDB.Error{code: :invalid_string}} = Reader.read_string(encoded)
  end
end
