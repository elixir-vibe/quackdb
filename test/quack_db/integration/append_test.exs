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

  test "Explorer dataframes append through column-oriented native append", %{
    conn: conn,
    table: table
  } do
    dataframe = Explorer.DataFrame.new(id: [1, 2], name: ["one", "two"], active: [true, false])

    assert %QuackDB.Result{num_rows: 2} =
             QuackDB.Explorer.insert_dataframe!(conn, table, dataframe, batch_size: 1)

    assert %QuackDB.Result{rows: [[1, "one", true], [2, "two", false]]} =
             QuackDB.query!(conn, "SELECT id, name, active FROM #{table} ORDER BY id")

    TestHelper.drop_table!(conn, table)
  end

  test "insert_columns appends column-oriented values", %{conn: conn, table: table} do
    assert %QuackDB.Result{num_rows: 3} =
             QuackDB.insert_columns!(
               conn,
               table,
               [id: [1, 2, 3], name: ["one", "two", "three"], active: [true, false, true]],
               columns: [id: :integer, name: :varchar, active: :boolean],
               batch_size: 2
             )

    assert %QuackDB.Result{rows: [[1, "one", true], [2, "two", false], [3, "three", true]]} =
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

  test "insert_columns appends ordinary Elixir maps to explicit MAP columns", %{conn: conn} do
    table = TestHelper.unique_table("append_column_map_events")

    TestHelper.create_table!(conn, table,
      id: :integer,
      labels: {:map, :varchar, :varchar}
    )

    assert %QuackDB.Result{num_rows: 3} =
             QuackDB.insert_columns!(
               conn,
               table,
               [id: [1, 2, 3], labels: [%{env: "prod", region: "eu"}, %{env: nil}, %{}]],
               columns: [id: :integer, labels: {:map, :varchar, :varchar}],
               batch_size: 2
             )

    assert %QuackDB.Result{rows: rows} =
             QuackDB.query!(conn, "SELECT id, labels FROM #{table} ORDER BY id")

    assert rows == [
             [1, %{"env" => "prod", "region" => "eu"}],
             [2, %{"env" => nil}],
             [3, %{}]
           ]

    TestHelper.drop_table!(conn, table)
  end

  test "insert_rows appends ordinary Elixir maps to explicit MAP columns", %{conn: conn} do
    table = TestHelper.unique_table("append_elixir_map_events")

    TestHelper.create_table!(conn, table,
      id: :integer,
      labels: {:map, :varchar, :varchar}
    )

    assert %QuackDB.Result{num_rows: 3} =
             QuackDB.insert_rows!(
               conn,
               table,
               [
                 [id: 1, labels: %{env: "prod", region: "eu"}],
                 [id: 2, labels: %{env: nil}],
                 [id: 3, labels: %{}]
               ],
               columns: [id: :integer, labels: {:map, :varchar, :varchar}],
               batch_size: 2
             )

    assert %QuackDB.Result{rows: rows} =
             QuackDB.query!(conn, "SELECT id, labels FROM #{table} ORDER BY id")

    assert rows == [
             [1, %{"env" => "prod", "region" => "eu"}],
             [2, %{"env" => nil}],
             [3, %{}]
           ]

    TestHelper.drop_table!(conn, table)
  end

  test "insert_rows appends ordinary Elixir maps inside nested MAP types", %{conn: conn} do
    table = TestHelper.unique_table("append_nested_map_events")

    TestHelper.create_table!(conn, table,
      id: :integer,
      metadata: {:struct, [source: :varchar, labels: {:map, :varchar, :varchar}]}
    )

    assert %QuackDB.Result{num_rows: 2} =
             QuackDB.insert_rows!(
               conn,
               table,
               [
                 [id: 1, metadata: %{source: "sensor", labels: %{env: "prod"}}],
                 [id: 2, metadata: %{source: "batch", labels: nil}]
               ],
               columns: [
                 id: :integer,
                 metadata: {:struct, [source: :varchar, labels: {:map, :varchar, :varchar}]}
               ]
             )

    assert %QuackDB.Result{rows: rows} =
             QuackDB.query!(conn, "SELECT id, metadata FROM #{table} ORDER BY id")

    assert rows == [
             [1, %{"source" => "sensor", "labels" => %{"env" => "prod"}}],
             [2, %{"source" => "batch", "labels" => nil}]
           ]

    TestHelper.drop_table!(conn, table)
  end

  test "insert_rows appends nullable scalar values", %{conn: conn} do
    table = TestHelper.unique_table("append_nullable_events")

    TestHelper.create_table!(conn, table,
      id: :integer,
      name: :varchar,
      active: :boolean,
      amount: {:decimal, 8, 2},
      tags: {:list, :varchar}
    )

    assert %QuackDB.Result{num_rows: 2} =
             QuackDB.insert_rows!(
               conn,
               table,
               [
                 [id: 1, name: nil, active: true, amount: nil, tags: ["duck", nil]],
                 [id: 2, name: "goose", active: nil, amount: Decimal.new("12.34"), tags: nil]
               ],
               columns: [
                 id: :integer,
                 name: :varchar,
                 active: :boolean,
                 amount: {:decimal, 8, 2},
                 tags: {:list, :varchar}
               ],
               batch_size: 1
             )

    assert %QuackDB.Result{rows: rows} =
             QuackDB.query!(
               conn,
               "SELECT id, name, active, amount, tags FROM #{table} ORDER BY id"
             )

    assert rows == [
             [1, nil, true, nil, ["duck", nil]],
             [2, "goose", nil, Decimal.new("12.34"), nil]
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
      precise_time: :time_ns,
      zoned_time: :time_tz,
      happened_at: :timestamp,
      happened_ns: :timestamp_ns,
      happened_tz: :timestamp_tz,
      span: :interval,
      big_value: :bignum,
      payload: :blob
    )

    row = [
      id: 1,
      amount: Decimal.new("123.45"),
      event_date: ~D[2026-05-25],
      event_time: ~T[12:34:56.123456],
      precise_time: QuackDB.NanosecondTime.new(45_296_123_456_789),
      zoned_time: QuackDB.TimeWithTimeZone.new(~T[12:34:56.123456], 3600),
      happened_at: ~N[2026-05-25 12:34:56.123456],
      happened_ns: QuackDB.NanosecondTimestamp.new(1_779_712_496_123_456_789),
      happened_tz: ~U[2026-05-25 12:34:56.123456Z],
      span: QuackDB.Interval.new(1, 2, 3),
      big_value: 123_456_789_012_345_678_901_234_567_890,
      payload: <<1, 2, 3>>
    ]

    assert %QuackDB.Result{num_rows: 1} =
             QuackDB.insert_rows!(conn, table, [row],
               columns: [
                 id: :integer,
                 amount: {:decimal, 8, 2},
                 event_date: :date,
                 event_time: :time,
                 precise_time: :time_ns,
                 zoned_time: :time_tz,
                 happened_at: :timestamp,
                 happened_ns: :timestamp_ns,
                 happened_tz: :timestamp_tz,
                 span: :interval,
                 big_value: :bignum,
                 payload: :blob
               ]
             )

    assert %QuackDB.Result{
             rows: [
               [
                 1,
                 amount,
                 date,
                 time,
                 time_ns,
                 time_tz,
                 naive,
                 timestamp_ns,
                 datetime,
                 span,
                 big_value,
                 payload
               ]
             ]
           } =
             QuackDB.query!(
               conn,
               "SELECT id, amount, event_date, event_time, precise_time, zoned_time, happened_at, happened_ns, happened_tz, span, big_value, payload FROM #{table}"
             )

    assert amount == Decimal.new("123.45")
    assert date == ~D[2026-05-25]
    assert time == ~T[12:34:56.123456]
    assert time_ns == QuackDB.NanosecondTime.new(45_296_123_456_789)
    assert time_tz == QuackDB.TimeWithTimeZone.new(~T[12:34:56.123456], 3600)
    assert naive == ~N[2026-05-25 12:34:56.123456]
    assert timestamp_ns == QuackDB.NanosecondTimestamp.new(1_779_712_496_123_456_789)
    assert datetime == ~U[2026-05-25 12:34:56.123456Z]
    assert span == QuackDB.Interval.new(1, 2, 3)
    assert big_value == 123_456_789_012_345_678_901_234_567_890
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
