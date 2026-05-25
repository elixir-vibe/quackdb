defmodule QuackDB.Integration.TimeSeriesTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "raw SQL supports generate_series for temporal ranges" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["generate_series"], rows: rows}} =
             QuackDB.query(
               connection,
               "SELECT * FROM generate_series(DATE '2024-01-01', DATE '2024-01-03', INTERVAL 1 DAY)"
             )

    assert rows == [
             [~N[2024-01-01 00:00:00.000000]],
             [~N[2024-01-02 00:00:00.000000]],
             [~N[2024-01-03 00:00:00.000000]]
           ]
  end

  test "raw SQL supports date_trunc and time_bucket" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["truncated", "bucket"], rows: [row]}} =
             QuackDB.query(
               connection,
               "SELECT date_trunc('day', TIMESTAMP '2024-01-02 03:04:05') AS truncated, time_bucket(INTERVAL '1 day', TIMESTAMP '2024-01-02 03:04:05') AS bucket"
             )

    assert row == [~N[2024-01-02 00:00:00.000000], ~N[2024-01-02 00:00:00.000000]]
  end

  test "raw SQL supports rolling analytical windows" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["ts", "rolling"], rows: rows}} =
             QuackDB.query(
               connection,
               """
               SELECT ts, avg(v) OVER (ORDER BY ts ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS rolling
               FROM (VALUES
                 (TIMESTAMP '2024-01-01', 10),
                 (TIMESTAMP '2024-01-02', 20),
                 (TIMESTAMP '2024-01-03', 30)
               ) AS t(ts, v)
               """
             )

    assert rows == [
             [~N[2024-01-01 00:00:00.000000], 10.0],
             [~N[2024-01-02 00:00:00.000000], 15.0],
             [~N[2024-01-03 00:00:00.000000], 25.0]
           ]
  end
end
