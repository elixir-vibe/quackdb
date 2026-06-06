defmodule QuackDB.StructTest do
  use ExUnit.Case, async: true

  alias QuackDB.Struct, as: DuckStruct

  test "builds struct function expressions" do
    expression = "{'name': 'duck', 'score': 10}"

    assert DuckStruct.extract(expression, "'score'") |> IO.iodata_to_binary() ==
             "struct_extract({'name': 'duck', 'score': 10}, 'score')"

    assert DuckStruct.extract_at("row(42, 84)", "1") |> IO.iodata_to_binary() ==
             "struct_extract_at(row(42, 84), 1)"

    assert DuckStruct.contains("row(1, 2, 3)", "2") |> IO.iodata_to_binary() ==
             "struct_contains(row(1, 2, 3), 2)"

    assert DuckStruct.position("row(1, 2, 3)", "2") |> IO.iodata_to_binary() ==
             "struct_position(row(1, 2, 3), 2)"

    assert DuckStruct.values(expression) |> IO.iodata_to_binary() ==
             "struct_values({'name': 'duck', 'score': 10})"

    assert DuckStruct.concat("{'name': 'duck'}", "{'score': 10}") |> IO.iodata_to_binary() ==
             "struct_concat({'name': 'duck'}, {'score': 10})"
  end
end
