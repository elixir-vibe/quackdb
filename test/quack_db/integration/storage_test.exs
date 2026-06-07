defmodule QuackDB.Integration.StorageTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "returns table storage info and compression summaries" do
    connection = start_connection!()
    table = "quackdb_storage_#{System.unique_integer([:positive])}"

    assert {:ok, _result} =
             QuackDB.query(
               connection,
               "CREATE TABLE #{table} AS SELECT i::INTEGER AS id, 'kind-' || (i % 3)::VARCHAR AS kind FROM range(1000) t(i)"
             )

    assert {:ok, segments} = QuackDB.Storage.info(connection, table)
    assert [%QuackDB.Storage.Segment{} | _] = segments
    assert Enum.any?(segments, &(&1.column_name == "id" and is_binary(&1.compression)))
    assert Enum.any?(segments, &(&1.column_name == "kind" and is_binary(&1.segment_type)))

    assert {:ok, %QuackDB.Storage.CompressionSummary{} = summary} =
             QuackDB.Storage.compression(connection, table)

    assert summary.source == table
    assert summary.columns["id"].segments > 0
    assert summary.columns["kind"].segments > 0
    assert map_size(summary.columns["id"].compressions) > 0

    assert [%QuackDB.Storage.DatabaseSize{} | _] = QuackDB.Storage.database_size!(connection)
  end

  test "accepts Ecto repos and schema modules" do
    start_repo!()

    QuackDB.IntegrationRepo.query!(
      "CREATE TEMP TABLE IF NOT EXISTS events (id INTEGER, name VARCHAR, score INTEGER, category_id INTEGER)"
    )

    QuackDB.IntegrationRepo.query!("INSERT INTO events VALUES (1, 'duck', 10, 1)")

    assert [%QuackDB.Storage.Segment{column_name: "id"} | _] =
             QuackDB.Storage.info!(QuackDB.IntegrationRepo, QuackDB.TestSchemas.Event)

    assert %QuackDB.Storage.CompressionSummary{source: "events"} =
             QuackDB.Storage.compression!(QuackDB.IntegrationRepo, QuackDB.TestSchemas.Event)
  end

  test "accepts prefixed table sources" do
    connection = start_connection!()
    schema = "quackdb_storage_schema_#{System.unique_integer([:positive])}"
    table = "events"

    assert {:ok, _result} = QuackDB.query(connection, "CREATE SCHEMA #{schema}")

    assert {:ok, _result} =
             QuackDB.query(
               connection,
               "CREATE TABLE #{schema}.#{table} AS SELECT i::INTEGER AS id FROM range(10) t(i)"
             )

    assert [%QuackDB.Storage.Segment{column_name: "id"} | _] =
             QuackDB.Storage.info!(connection, {schema, table})
  end
end
