defmodule QuackDB.MapTest do
  use ExUnit.Case, async: true

  alias QuackDB.Map, as: DuckMap

  test "builds map function expressions" do
    expression = "map(['env'], ['prod'])"

    assert DuckMap.cardinality(expression) |> IO.iodata_to_binary() ==
             "cardinality(map(['env'], ['prod']))"

    assert DuckMap.keys(expression) |> IO.iodata_to_binary() == "map_keys(map(['env'], ['prod']))"

    assert DuckMap.values(expression) |> IO.iodata_to_binary() ==
             "map_values(map(['env'], ['prod']))"

    assert DuckMap.entries(expression) |> IO.iodata_to_binary() ==
             "map_entries(map(['env'], ['prod']))"

    assert DuckMap.contains(expression, "'env'") |> IO.iodata_to_binary() ==
             "map_contains(map(['env'], ['prod']), 'env')"

    assert DuckMap.contains_entry(expression, "'env'", "'prod'") |> IO.iodata_to_binary() ==
             "map_contains_entry(map(['env'], ['prod']), 'env', 'prod')"

    assert DuckMap.contains_value(expression, "'prod'") |> IO.iodata_to_binary() ==
             "map_contains_value(map(['env'], ['prod']), 'prod')"

    assert DuckMap.extract(expression, "'env'") |> IO.iodata_to_binary() ==
             "map_extract(map(['env'], ['prod']), 'env')"

    assert DuckMap.extract_value(expression, "'env'") |> IO.iodata_to_binary() ==
             "map_extract_value(map(['env'], ['prod']), 'env')"

    assert DuckMap.concat(expression, "map(['region'], ['eu'])") |> IO.iodata_to_binary() ==
             "map_concat(map(['env'], ['prod']), map(['region'], ['eu']))"
  end
end
