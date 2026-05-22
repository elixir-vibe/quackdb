defmodule QuackDB.Protocol.ReaderWriterTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Reader
  alias QuackDB.Protocol.Writer

  describe "unsigned LEB128" do
    test "roundtrips values" do
      for value <- [0, 1, 127, 128, 255, 16_384, 624_485, 0xFFFF_FFFF_FFFF_FFFF] do
        binary = IO.iodata_to_binary(Writer.uleb128(value))
        assert {:ok, ^value, ""} = Reader.read_uleb128(binary)
      end
    end

    test "uses the expected byte representation" do
      assert IO.iodata_to_binary(Writer.uleb128(624_485)) == <<0xE5, 0x8E, 0x26>>
    end
  end

  describe "signed LEB128" do
    test "roundtrips values" do
      for value <- [-624_485, -129, -128, -1, 0, 1, 63, 64, 127, 128, 624_485] do
        binary = IO.iodata_to_binary(Writer.sleb128(value))
        assert {:ok, ^value, ""} = Reader.read_sleb128(binary)
      end
    end

    test "uses the expected byte representation" do
      assert IO.iodata_to_binary(Writer.sleb128(-624_485)) == <<0x9B, 0xF1, 0x59>>
    end
  end

  test "reads and writes strings" do
    binary = IO.iodata_to_binary(Writer.string("duck"))

    assert binary == <<4, "duck">>
    assert {:ok, "duck", ""} = Reader.read_string(binary)
  end

  test "reads and writes hugeints" do
    for value <- [
          -12_345_678_901_234_567_890_123_456_789,
          -1,
          0,
          1,
          12_345_678_901_234_567_890_123_456_789
        ] do
      binary = IO.iodata_to_binary(Writer.hugeint(value))

      assert {:ok, ^value, ""} = Reader.read_hugeint(binary)
    end
  end
end
