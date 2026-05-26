defmodule QuackDB.InspectMoreTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.LogicalType

  test "inspects streams compactly" do
    stream = %QuackDB.Stream{
      conn: self(),
      query: %QuackDB.Query{statement: String.duplicate("SELECT * FROM events ", 10)},
      params: [1, 2],
      options: [max_rows: 100]
    }

    inspected = inspect(stream)

    assert inspected =~ "#QuackDB.Stream<"
    assert inspected =~ "statement: \"SELECT * FROM events"
    assert inspected =~ "…"
    assert inspected =~ "params: 2"
    assert inspected =~ "options: [max_rows: 100]"
  end

  test "inspects cursors compactly" do
    cursor = %QuackDB.Cursor{
      ref: make_ref(),
      result_uuid: 42,
      columns: ["n"],
      connection_id: "1234567890abcdef"
    }

    assert inspect(cursor) ==
             "#QuackDB.Cursor<result_uuid: 42, columns: [\"n\"], connection_id: \"1234567890ab…\">"
  end

  test "inspects DuckDB-specific scalar structs compactly" do
    assert inspect(QuackDB.Interval.new(1, 2, 3)) ==
             "#QuackDB.Interval<1 months, 2 days, 3 microseconds>"

    assert inspect(QuackDB.NanosecondTime.new(1_234_567_890)) ==
             "#QuackDB.NanosecondTime<1234567890 ns>"

    assert inspect(QuackDB.NanosecondTimestamp.new(1_234_567_890)) ==
             "#QuackDB.NanosecondTimestamp<1234567890 ns>"

    assert inspect(QuackDB.TimeWithTimeZone.new(~T[12:34:56.123456], 3600)) ==
             "#QuackDB.TimeWithTimeZone<12:34:56.123456+01:00>"
  end

  test "inspects data chunks as summaries" do
    chunk = %DataChunk{
      row_count: 2,
      types: [%LogicalType{name: :integer}, %LogicalType{name: :varchar}],
      columns: [
        %{type: %LogicalType{name: :integer}, vector_type: :flat, values: [1, 2]},
        %{type: %LogicalType{name: :varchar}, vector_type: :flat, values: ["duck", "goose"]}
      ]
    }

    assert inspect(chunk) ==
             "#QuackDB.DataChunk<rows: 2, columns: 2, types: [:integer, :varchar]>"
  end
end
