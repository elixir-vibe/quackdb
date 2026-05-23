defmodule QuackDB.ResultTest do
  use ExUnit.Case, async: true

  alias QuackDB.Result

  test "normalizes DML count results into affected row counts" do
    result = %Result{
      command: :insert,
      columns: ["Count"],
      rows: [[2]],
      num_rows: 1,
      metadata: %{result_uuid: 123}
    }

    assert Result.normalize(result) == %Result{
             command: :insert,
             columns: nil,
             rows: nil,
             num_rows: 2,
             metadata: %{result_uuid: 123, duckdb_columns: ["Count"], duckdb_rows: [[2]]}
           }
  end

  test "normalizes schema command count results into command-only results" do
    result = %Result{command: :create, columns: ["Count"], rows: [], num_rows: 0}

    assert Result.normalize(result) == %Result{
             command: :create,
             columns: nil,
             rows: nil,
             num_rows: 0,
             metadata: %{duckdb_columns: ["Count"], duckdb_rows: []}
           }
  end

  test "leaves select results unchanged" do
    result = %Result{command: :select, columns: ["Count"], rows: [[2]], num_rows: 1}

    assert Result.normalize(result) == result
  end

  test "converts row results to column-oriented maps and structs" do
    result = %Result{
      columns: ["id", "name"],
      rows: [[1, "duck"], [2, "goose"]],
      num_rows: 2,
      metadata: %{source: :fixture}
    }

    assert Result.to_columns(result) == %{"id" => [1, 2], "name" => ["duck", "goose"]}

    assert %QuackDB.Columns{
             names: ["id", "name"],
             original_names: ["id", "name"],
             columns: %{"id" => [1, 2], "name" => ["duck", "goose"]},
             num_rows: 2,
             metadata: %{source: :fixture}
           } = Result.to_columnar(result)
  end

  test "disambiguates duplicate column names in column-oriented maps" do
    result = %Result{columns: ["x", "x", "x"], rows: [[1, 2, 3]], num_rows: 1}

    assert Result.to_columns(result) == %{"x" => [1], "x_2" => [2], "x_3" => [3]}
  end

  test "returns an empty column map for command results" do
    result = %Result{command: :create, columns: nil, rows: nil, metadata: %{duckdb_rows: []}}

    assert Result.to_columns(result) == %{}

    assert %QuackDB.Columns{
             names: [],
             columns: %{},
             command: :create,
             metadata: %{duckdb_rows: []}
           } = Result.to_columnar(result)
  end

  test "column structs support access enumerable rows and maps" do
    columns =
      Result.to_columnar(%Result{
        columns: ["id", "name"],
        rows: [[1, "duck"], [2, "goose"]],
        num_rows: 2
      })

    assert columns["id"] == [1, 2]
    assert Enum.to_list(columns) == [{"id", [1, 2]}, {"name", ["duck", "goose"]}]
    assert QuackDB.Columns.to_rows(columns) == [[1, "duck"], [2, "goose"]]

    assert QuackDB.Columns.to_maps(columns) == [
             %{"id" => 1, "name" => "duck"},
             %{"id" => 2, "name" => "goose"}
           ]
  end
end
