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
end
