defmodule QuackDB.SourceTest do
  use ExUnit.Case, async: true

  alias QuackDB.Source

  test "builds parquet fragments for one path" do
    assert Source.parquet("events.parquet") == "read_parquet('events.parquet')"
  end

  test "builds parquet fragments for path lists and options" do
    assert Source.parquet(["s3://bucket/a.parquet", "s3://bucket/b.parquet"],
             hive_partitioning: true,
             union_by_name: true
           ) ==
             "read_parquet(['s3://bucket/a.parquet', 's3://bucket/b.parquet'], hive_partitioning = TRUE, union_by_name = TRUE)"
  end

  test "escapes paths and string options" do
    assert Source.csv("data/robert's.csv", delim: "|", nullstr: "N/A") ==
             "read_csv('data/robert''s.csv', delim = '|', nullstr = 'N/A')"
  end

  test "formats DuckDB struct options from maps" do
    assert Source.csv("events.csv", header: true, columns: %{id: "INTEGER", name: "VARCHAR"}) ==
             "read_csv('events.csv', header = TRUE, columns = {'id': 'INTEGER', 'name': 'VARCHAR'})"
  end

  test "formats nested structs and DuckDB maps" do
    assert Source.parquet("integers.parquet",
             schema:
               {:map,
                %{
                  0 => {:struct, %{name: "renamed_i", type: "BIGINT", default_value: nil}},
                  1 => {:struct, %{name: "new_column", type: "UTINYINT", default_value: 43}}
                }}
           ) ==
             "read_parquet('integers.parquet', schema = MAP {0: {'name': 'renamed_i', 'type': 'BIGINT', 'default_value': NULL}, 1: {'name': 'new_column', 'type': 'UTINYINT', 'default_value': 43}})"
  end

  test "builds JSON XLSX Delta and Iceberg fragments" do
    assert Source.json("events.json", format: "array") ==
             "read_json('events.json', format = 'array')"

    assert Source.xlsx("book.xlsx", sheet: "Sheet1", range: "A1:B2") ==
             "read_xlsx('book.xlsx', sheet = 'Sheet1', range = 'A1:B2')"

    assert Source.delta("s3://bucket/table", version: 5) ==
             "delta_scan('s3://bucket/table', version = 5)"

    assert Source.iceberg("s3://bucket/table", allow_moved_paths: true) ==
             "iceberg_scan('s3://bucket/table', allow_moved_paths = TRUE)"
  end

  test "builds histogram values sources" do
    assert Source.histogram_values("events", :score, bin_count: 10) ==
             "histogram_values(events, score, bin_count := 10)"
  end

  test "wraps sources with sampling" do
    source = Source.parquet("events.parquet")

    assert Source.sample(source, rows: 10) ==
             "(SELECT * FROM read_parquet('events.parquet') USING SAMPLE 10 ROWS)"

    assert Source.sample(source, percent: 12.5) ==
             "(SELECT * FROM read_parquet('events.parquet') USING SAMPLE 12.5 PERCENT)"
  end

  test "identifies source fragments for Ecto SQL generation" do
    assert Source.source?(Source.csv("events.csv", header: true))
    refute Source.source?("events")
  end

  test "rejects unsafe option and function names" do
    assert_raise ArgumentError, ~r/invalid DuckDB option identifier/, fn ->
      Source.parquet("events.parquet", [{"bad option", true}])
    end

    assert_raise ArgumentError, ~r/invalid DuckDB function identifier/, fn ->
      Source.table_function("read_parquet); DROP TABLE events; --", "events.parquet")
    end
  end
end
