defmodule QuackDB.Integration.ColumnarTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "column-oriented query results against a real Quack server" do
    connection = start_connection!()

    assert {:ok, %{"id" => [1, 2], "name" => ["duck", "goose"]}} =
             QuackDB.columns(
               connection,
               "SELECT * FROM (VALUES (1, 'duck'), (2, 'goose')) AS t(id, name) ORDER BY id"
             )

    assert {:ok, %QuackDB.Columns{names: ["id", "name"], num_rows: 2} = columns} =
             QuackDB.columnar(
               connection,
               "SELECT * FROM (VALUES (1, 'duck'), (2, 'goose')) AS t(id, name) ORDER BY id"
             )

    assert columns["id"] == [1, 2]

    assert {:ok, [%{"n" => [0, 1, 2]}, %{"n" => [3, 4, 5]}]} =
             DBConnection.transaction(connection, fn tx ->
               tx
               |> QuackDB.column_batches("SELECT i::INTEGER AS n FROM range(0, 6) t(i)", [],
                 max_rows: 3
               )
               |> Enum.to_list()
             end)

    assert {:ok,
            [
              %QuackDB.Columns{names: ["n"], num_rows: 3} = first_batch,
              %QuackDB.Columns{names: ["n"], num_rows: 3}
            ]} =
             DBConnection.transaction(connection, fn tx ->
               tx
               |> QuackDB.columnar_batches("SELECT i::INTEGER AS n FROM range(0, 6) t(i)", [],
                 max_rows: 3
               )
               |> Enum.to_list()
             end)

    assert first_batch["n"] == [0, 1, 2]
  end
end
