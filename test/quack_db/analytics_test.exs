defmodule QuackDB.AnalyticsTest do
  use ExUnit.Case, async: true

  test "builds summarize queries" do
    assert QuackDB.Analytics.summarize(:events) |> IO.iodata_to_binary() ==
             ~s|SUMMARIZE SELECT * FROM "events"|

    assert QuackDB.Analytics.summarize({:query, "SELECT 1 AS id"}) |> IO.iodata_to_binary() ==
             "SUMMARIZE SELECT 1 AS id"
  end
end
