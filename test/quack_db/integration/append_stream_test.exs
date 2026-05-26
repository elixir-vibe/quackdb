defmodule QuackDB.Integration.AppendStreamTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase
  import QuackDB.TestHelper

  @moduletag :integration

  test "insert_stream appends enumerable rows" do
    connection = start_connection!()
    table = unique_table("quackdb_insert_stream")

    create_table!(connection, table, id: :integer, name: :varchar)

    rows = Stream.map(1..3, fn id -> %{id: id, name: "event-#{id}"} end)

    assert %QuackDB.Result{} = QuackDB.insert_stream!(connection, table, rows, chunk_every: 2)

    assert %{rows: [[3]]} = QuackDB.query!(connection, "SELECT count(*) FROM #{table}")
  end

  test "insert_table appends Table.Reader-compatible columns" do
    connection = start_connection!()
    table = unique_table("quackdb_insert_table")

    create_table!(connection, table, id: :integer, name: :varchar)

    assert %QuackDB.Result{} =
             QuackDB.insert_table!(connection, table, %{id: [1, 2], name: ["duck", "goose"]})

    assert %{rows: [["duck"], ["goose"]]} =
             QuackDB.query!(connection, "SELECT name FROM #{table} ORDER BY id")
  end
end
