defmodule QuackDB.Protocol.LogicalTypeTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.LogicalType
  alias QuackDB.Protocol.Writer

  test "decodes unknown logical type ids as unsupported names" do
    binary =
      [
        Writer.field(100, Writer.uleb128(999_999)),
        Writer.end_object()
      ]
      |> IO.iodata_to_binary()

    assert {:ok, %LogicalType{id: 999_999, name: nil, type_info: nil}, ""} =
             LogicalType.decode(binary)
  end

  test "reports missing logical type ids" do
    binary =
      [
        Writer.field(101, Writer.nullable(nil, &Function.identity/1)),
        Writer.end_object()
      ]
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :invalid_logical_type, message: message}} =
             LogicalType.decode(binary)

    assert message == "logical type is missing id field"
  end

  test "reports unknown logical type fields" do
    binary =
      [
        Writer.field(999, Writer.uleb128(1)),
        Writer.end_object()
      ]
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :unknown_logical_type_field, message: message}} =
             LogicalType.decode(binary)

    assert message == "unknown logical type field 999"
  end

  test "reports logical type metadata without type fields" do
    binary =
      [
        Writer.field(100, Writer.uleb128(LogicalType.id(:decimal))),
        Writer.field(
          101,
          Writer.nullable(
            [Writer.field(101, Writer.string("alias")), Writer.end_object()],
            &Function.identity/1
          )
        ),
        Writer.end_object()
      ]
      |> IO.iodata_to_binary()

    assert {:error, %QuackDB.Error{code: :invalid_logical_type_info, message: message}} =
             LogicalType.decode(binary)

    assert message == "logical type metadata is missing type field"
  end

  test "reports unknown logical type metadata fields" do
    binary =
      logical_type_with_info([
        Writer.field(100, Writer.uleb128(2)),
        Writer.field(999, Writer.uleb128(1)),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unknown_type_info_field, message: message}} =
             LogicalType.decode(binary)

    assert message == "unknown logical type metadata field 999"
  end

  test "reports incomplete child type fields" do
    child = [Writer.field(0, Writer.string("value")), Writer.end_object()]

    binary =
      logical_type_with_info([
        Writer.field(100, Writer.uleb128(5)),
        Writer.field(200, Writer.list([child], &Function.identity/1)),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :invalid_child_type, message: message}} =
             LogicalType.decode(binary)

    assert message == ~s|child type must include name and type fields, got %{name: "value"}|
  end

  test "reports unknown child type fields" do
    child = [Writer.field(999, Writer.string("bad")), Writer.end_object()]

    binary =
      logical_type_with_info([
        Writer.field(100, Writer.uleb128(5)),
        Writer.field(200, Writer.list([child], &Function.identity/1)),
        Writer.end_object()
      ])

    assert {:error, %QuackDB.Error{code: :unknown_child_type_field, message: message}} =
             LogicalType.decode(binary)

    assert message == "unknown child type field 999"
  end

  test "reports missing metadata when using decoded incomplete types" do
    decimal = %LogicalType{id: LogicalType.id(:decimal), name: :decimal, type_info: %{type: 2}}
    list = %LogicalType{id: LogicalType.id(:list), name: :list, type_info: %{type: 4}}
    array = %LogicalType{id: LogicalType.id(:array), name: :array, type_info: %{type: 9}}

    assert_raise QuackDB.Error, ~r/unsupported logical type/, fn ->
      LogicalType.physical_type(decimal)
    end

    assert_raise QuackDB.Error, ~r/does not have child metadata/, fn ->
      LogicalType.child_type(list)
    end

    assert_raise QuackDB.Error, ~r/does not have array size metadata/, fn ->
      LogicalType.array_size(array)
    end
  end

  defp logical_type_with_info(info) do
    [
      Writer.field(100, Writer.uleb128(LogicalType.id(:decimal))),
      Writer.field(101, Writer.nullable(info, &Function.identity/1)),
      Writer.end_object()
    ]
    |> IO.iodata_to_binary()
  end
end
