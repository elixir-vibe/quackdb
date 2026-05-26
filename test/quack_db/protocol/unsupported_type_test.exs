defmodule QuackDB.Protocol.UnsupportedTypeTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.LogicalType

  test "reports UNION vectors as unsupported" do
    type = %LogicalType{id: 107, name: :union, type_info: %{type: 5, children: []}}

    assert_raise QuackDB.Error, ~r/unsupported logical type/, fn ->
      DataChunk.encode_wrapper(%DataChunk{
        row_count: 0,
        types: [type],
        columns: [%{type: type, vector_type: :flat, values: []}]
      })
    end
  end

  test "reports VARIANT vectors as unsupported" do
    type = %LogicalType{id: 109, name: :variant, type_info: %{type: 5, children: []}}

    assert_raise QuackDB.Error, ~r/unsupported logical type/, fn ->
      DataChunk.encode_wrapper(%DataChunk{
        row_count: 0,
        types: [type],
        columns: [%{type: type, vector_type: :flat, values: []}]
      })
    end
  end

  test "reports unsupported aggregate state metadata explicitly" do
    type = %LogicalType{id: LogicalType.id(:varchar), name: :varchar, type_info: %{type: 8}}

    assert_raise QuackDB.Error, ~r/encoding logical type metadata/, fn ->
      type |> LogicalType.encode() |> IO.iodata_to_binary()
    end
  end
end
