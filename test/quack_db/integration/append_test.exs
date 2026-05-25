defmodule QuackDB.Integration.AppendTest do
  use ExUnit.Case, async: false

  alias QuackDB.TestHelper

  @moduletag :integration

  setup do
    conn = QuackDB.QuackServerCase.start_connection!()
    table = TestHelper.unique_table("append_events")
    TestHelper.create_table!(conn, table, id: :integer, name: :varchar, active: :boolean)

    {:ok, conn: conn, table: table}
  end

  test "insert_rows infers ordered columns from keyword rows", %{conn: conn, table: table} do
    assert %QuackDB.Result{command: :insert, num_rows: 2} =
             QuackDB.insert_rows!(conn, table, [
               [id: 1, name: "one", active: true],
               [id: 2, name: "two", active: false]
             ])

    assert %QuackDB.Result{rows: [[1, "one", true], [2, "two", false]]} =
             QuackDB.query!(conn, "SELECT id, name, active FROM #{table} ORDER BY id")

    TestHelper.drop_table!(conn, table)
  end

  test "insert_rows batches row appends", %{conn: conn, table: table} do
    assert %QuackDB.Result{num_rows: 3} =
             QuackDB.insert_rows!(
               conn,
               table,
               [
                 [id: 1, name: "one", active: true],
                 [id: 2, name: "two", active: false],
                 [id: 3, name: "three", active: true]
               ],
               batch_size: 2
             )

    assert %QuackDB.Result{rows: [[1], [2], [3]]} =
             QuackDB.query!(conn, "SELECT id FROM #{table} ORDER BY id")

    TestHelper.drop_table!(conn, table)
  end

  test "insert_rows appends nested DuckDB types", %{conn: conn} do
    table = TestHelper.unique_table("append_nested_events")

    TestHelper.create_table!(conn, table,
      id: :integer,
      tags: {:list, :varchar},
      metadata: {:struct, [source: :varchar, count: :integer]},
      scores: {:array, :integer, 3},
      labels: {:map, :varchar, :varchar}
    )

    assert %QuackDB.Result{num_rows: 2} =
             QuackDB.insert_rows!(
               conn,
               table,
               [
                 [
                   id: 1,
                   tags: ["duck", "analytics"],
                   metadata: %{source: "sensor", count: 2},
                   scores: [10, 20, 30],
                   labels: [%{key: "env", value: "test"}]
                 ],
                 [
                   id: 2,
                   tags: [],
                   metadata: %{source: "batch", count: nil},
                   scores: [40, 50, 60],
                   labels: nil
                 ]
               ],
               columns: [
                 id: :integer,
                 tags: {:list, :varchar},
                 metadata: {:struct, [source: :varchar, count: :integer]},
                 scores: {:array, :integer, 3},
                 labels: {:map, :varchar, :varchar}
               ]
             )

    assert %QuackDB.Result{rows: rows} =
             QuackDB.query!(
               conn,
               "SELECT id, tags, metadata, scores, labels FROM #{table} ORDER BY id"
             )

    assert rows == [
             [
               1,
               ["duck", "analytics"],
               %{"source" => "sensor", "count" => 2},
               [10, 20, 30],
               %{"env" => "test"}
             ],
             [2, [], %{"source" => "batch", "count" => nil}, [40, 50, 60], nil]
           ]

    TestHelper.drop_table!(conn, table)
  end

  test "insert_rows appends common scalar DuckDB types", %{conn: conn} do
    table = TestHelper.unique_table("append_typed_events")

    TestHelper.create_table!(conn, table,
      id: :integer,
      amount: {:decimal, 8, 2},
      event_date: :date,
      event_time: :time,
      happened_at: :timestamp,
      happened_tz: :timestamp_tz,
      payload: :blob
    )

    row = [
      id: 1,
      amount: Decimal.new("123.45"),
      event_date: ~D[2026-05-25],
      event_time: ~T[12:34:56.123456],
      happened_at: ~N[2026-05-25 12:34:56.123456],
      happened_tz: ~U[2026-05-25 12:34:56.123456Z],
      payload: <<1, 2, 3>>
    ]

    assert %QuackDB.Result{num_rows: 1} =
             QuackDB.insert_rows!(conn, table, [row],
               columns: [
                 id: :integer,
                 amount: {:decimal, 8, 2},
                 event_date: :date,
                 event_time: :time,
                 happened_at: :timestamp,
                 happened_tz: :timestamp_tz,
                 payload: :blob
               ]
             )

    assert %QuackDB.Result{rows: [[1, amount, date, time, naive, datetime, payload]]} =
             QuackDB.query!(
               conn,
               "SELECT id, amount, event_date, event_time, happened_at, happened_tz, payload FROM #{table}"
             )

    assert amount == Decimal.new("123.45")
    assert date == ~D[2026-05-25]
    assert time == ~T[12:34:56.123456]
    assert naive == ~N[2026-05-25 12:34:56.123456]
    assert datetime == ~U[2026-05-25 12:34:56.123456Z]
    assert payload == <<1, 2, 3>>

    TestHelper.drop_table!(conn, table)
  end

  test "insert_rows supports explicit columns for empty batches", %{conn: conn, table: table} do
    assert %QuackDB.Result{num_rows: 0} =
             QuackDB.insert_rows!(conn, table, [],
               columns: [id: :integer, name: :varchar, active: :boolean]
             )

    assert %QuackDB.Result{rows: [[0]]} = QuackDB.query!(conn, "SELECT count(*) FROM #{table}")

    TestHelper.drop_table!(conn, table)
  end
end
