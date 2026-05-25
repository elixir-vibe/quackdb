defmodule QuackDB.Integration.StreamTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "streams large result sets from a real Quack server" do
    connection = start_connection!()

    assert {:ok, rows} =
             DBConnection.transaction(connection, fn tx ->
               tx
               |> QuackDB.stream("SELECT i::INTEGER AS n FROM range(0, 50000) t(i)", [],
                 max_rows: 1000
               )
               |> Enum.flat_map(& &1.rows)
             end)

    assert Enum.count(rows) == 50_000
    assert hd(rows) == [0]
    assert Enum.at(rows, -1) == [49_999]
  end

  test "streams rows and maps from a real Quack server" do
    connection = start_connection!()

    assert {:ok, first_rows} =
             DBConnection.transaction(connection, fn tx ->
               tx
               |> QuackDB.rows("SELECT i::INTEGER AS n FROM range(0, ?) t(i)", [50_000],
                 max_rows: 1000
               )
               |> Enum.take(5)
             end)

    assert first_rows == [[0], [1], [2], [3], [4]]

    assert {:ok, first_maps} =
             DBConnection.transaction(connection, fn tx ->
               tx
               |> QuackDB.maps("SELECT i::INTEGER AS n FROM range(0, ?) t(i)", [50_000],
                 max_rows: 1000
               )
               |> Enum.take(3)
             end)

    assert first_maps == [%{"n" => 0}, %{"n" => 1}, %{"n" => 2}]
  end
end
