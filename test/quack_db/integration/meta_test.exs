defmodule QuackDB.Integration.MetaTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "lists tables and table columns" do
    connection = start_connection!()
    table = "quackdb_meta_#{System.unique_integer([:positive])}"

    assert {:ok, _result} =
             QuackDB.query(
               connection,
               "CREATE TEMP TABLE #{table} (id INTEGER, name VARCHAR NOT NULL)"
             )

    assert {:ok, tables} = QuackDB.Meta.tables(connection)
    assert Enum.any?(tables, &match?(%QuackDB.Meta.Table{name: ^table}, &1))

    assert {:ok, expanded_tables} = QuackDB.Meta.tables(connection, expanded: true)

    assert Enum.any?(
             expanded_tables,
             &match?(%QuackDB.Meta.Table{name: ^table, schema: "main", temporary: true}, &1)
           )

    assert [
             %QuackDB.Meta.Column{name: "id", type: "INTEGER"},
             %QuackDB.Meta.Column{name: "name", type: "VARCHAR", notnull: true}
           ] = QuackDB.Meta.table_info!(connection, table)
  end

  test "lists attached databases" do
    connection = start_connection!()

    assert [%QuackDB.Meta.Database{name: "memory"} | _] = QuackDB.Meta.databases!(connection)
  end

  test "accepts Ecto repos and schema modules" do
    start_repo!()

    QuackDB.IntegrationRepo.query!(
      "CREATE TEMP TABLE IF NOT EXISTS events (id INTEGER, name VARCHAR, score INTEGER, category_id INTEGER)"
    )

    assert Enum.any?(QuackDB.Meta.tables!(QuackDB.IntegrationRepo), &(&1.name == "events"))

    assert [
             %QuackDB.Meta.Column{name: "id", type: "INTEGER"},
             %QuackDB.Meta.Column{name: "name", type: "VARCHAR"},
             %QuackDB.Meta.Column{name: "score", type: "INTEGER"},
             %QuackDB.Meta.Column{name: "category_id", type: "INTEGER"}
           ] = QuackDB.Meta.table_info!(QuackDB.IntegrationRepo, QuackDB.TestSchemas.Event)
  end
end
