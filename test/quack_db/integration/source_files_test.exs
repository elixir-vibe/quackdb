defmodule QuackDB.Integration.SourceFilesTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "source helpers query CSV and Parquet files against a real Quack server" do
    connection = start_connection!()

    csv_path =
      Path.join(System.tmp_dir!(), "quackdb_source_#{System.unique_integer([:positive])}.csv")

    parquet_path =
      Path.join(System.tmp_dir!(), "quackdb_source_#{System.unique_integer([:positive])}.parquet")

    File.write!(csv_path, "id,name\n1,duck\n2,goose\n")

    on_exit(fn ->
      File.rm(csv_path)
      File.rm(parquet_path)
    end)

    csv_source = QuackDB.Source.csv(csv_path, header: true)

    assert {:ok, %QuackDB.Result{columns: ["id", "name"], rows: [[1, "duck"], [2, "goose"]]}} =
             QuackDB.query(connection, ["SELECT id, name FROM ", csv_source, " ORDER BY id"])

    QuackDB.query!(
      connection,
      "COPY (SELECT 1 AS id, 'duck' AS name UNION ALL SELECT 2 AS id, 'goose' AS name) TO ? (FORMAT parquet)",
      [parquet_path]
    )

    parquet_source = QuackDB.Source.parquet(parquet_path)

    assert {:ok, %QuackDB.Result{columns: ["id", "name"], rows: [[1, "duck"], [2, "goose"]]}} =
             QuackDB.query(connection, ["SELECT id, name FROM ", parquet_source, " ORDER BY id"])
  end
end
