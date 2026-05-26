defmodule QuackDB.Protocol.FSSTTest do
  use ExUnit.Case, async: true

  test "decompresses payloads with serialized symbols" do
    table = FSST.Table.from_symbols!(["hello", " world"])

    assert {:ok, ["hello world!"]} =
             QuackDB.Protocol.FSST.decompress_values(["hello", " world"], [<<0, 1, 255, ?!>>])

    assert {:ok, "hello world!"} = FSST.decompress(table, <<0, 1, 255, ?!>>)
  end

  test "reports invalid symbols" do
    assert {:error, %QuackDB.Error{code: :invalid_fsst_symbols}} =
             QuackDB.Protocol.FSST.decompress_values([""], [<<>>])
  end
end
