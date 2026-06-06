defmodule QuackDB.ListTest do
  use ExUnit.Case, async: true

  alias QuackDB.List, as: DuckList

  test "builds list function expressions" do
    assert DuckList.length(~s|"terms"|) |> IO.iodata_to_binary() == ~s|len("terms")|

    assert DuckList.extract(~s|"terms"|, "1") |> IO.iodata_to_binary() ==
             ~s|list_extract("terms", 1)|

    assert DuckList.slice(~s|"terms"|, "1", "2") |> IO.iodata_to_binary() ==
             ~s|list_slice("terms", 1, 2)|

    assert DuckList.slice(~s|"terms"|, "1", "3", "2") |> IO.iodata_to_binary() ==
             ~s|list_slice("terms", 1, 3, 2)|

    assert DuckList.sort(~s|"terms"|) |> IO.iodata_to_binary() == ~s|list_sort("terms")|

    assert DuckList.reverse_sort(~s|"terms"|) |> IO.iodata_to_binary() ==
             ~s|list_reverse_sort("terms")|

    assert DuckList.distinct(~s|"terms"|) |> IO.iodata_to_binary() ==
             ~s|list_distinct("terms")|

    assert DuckList.unique(~s|"terms"|) |> IO.iodata_to_binary() == ~s|list_unique("terms")|

    assert DuckList.position(~s|"terms"|, "42") |> IO.iodata_to_binary() ==
             ~s|list_position("terms", 42)|

    assert DuckList.contains(~s|"terms"|, "42") |> IO.iodata_to_binary() ==
             ~s|list_contains("terms", 42)|

    assert DuckList.has_any(~s|"terms"|, "[1, 2]") |> IO.iodata_to_binary() ==
             ~s|list_has_any("terms", [1, 2])|

    assert DuckList.has_all(~s|"terms"|, "[1, 2]") |> IO.iodata_to_binary() ==
             ~s|list_has_all("terms", [1, 2])|

    assert DuckList.intersect(~s|"terms"|, "[1, 2]") |> IO.iodata_to_binary() ==
             ~s|list_intersect("terms", [1, 2])|

    assert DuckList.concat(~s|"terms"|, "[1, 2]") |> IO.iodata_to_binary() ==
             ~s|list_concat("terms", [1, 2])|

    assert DuckList.unnest(~s|"terms"|) |> IO.iodata_to_binary() == ~s|unnest("terms")|
  end
end
