defmodule QuackDB.ListTest do
  use ExUnit.Case, async: true

  alias QuackDB.List, as: DuckList

  test "builds list function expressions" do
    assert DuckList.contains(~s|"terms"|, "42") |> IO.iodata_to_binary() ==
             ~s|list_contains("terms", 42)|

    assert DuckList.has_any(~s|"terms"|, "[1, 2]") |> IO.iodata_to_binary() ==
             ~s|list_has_any("terms", [1, 2])|

    assert DuckList.has_all(~s|"terms"|, "[1, 2]") |> IO.iodata_to_binary() ==
             ~s|list_has_all("terms", [1, 2])|

    assert DuckList.unnest(~s|"terms"|) |> IO.iodata_to_binary() == ~s|unnest("terms")|
  end
end
