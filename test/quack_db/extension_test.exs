defmodule QuackDB.ExtensionTest do
  use ExUnit.Case, async: true

  test "builds extension install and load statements" do
    assert QuackDB.Extension.install(:httpfs) |> IO.iodata_to_binary() == "INSTALL httpfs;"
    assert QuackDB.Extension.load(:httpfs) |> IO.iodata_to_binary() == "LOAD httpfs;"
  end

  test "rejects invalid extension names" do
    assert_raise ArgumentError, ~r/invalid SQL extension identifier/, fn ->
      QuackDB.Extension.load("bad-name")
    end
  end
end
