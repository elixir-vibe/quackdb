defmodule QuackDB.Integration.Ecto.QueryTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.Ecto.Spatial, only: [as_text: 1, distance: 2, intersects: 2]
  import QuackDB.QuackServerCase
  import QuackDB.TestHelper

  @moduletag :integration

  test "Ecto Repo.query/3 works against a real Quack server" do
    start_repo!()

    assert {:ok, %{columns: ["n"], rows: [[1]], num_rows: 1, command: :select}} =
             QuackDB.IntegrationRepo.query("SELECT 1 AS n")

    table = unique_table("quackdb_ecto")

    assert %{command: :create, rows: nil, num_rows: 0} =
             create_table!(QuackDB.IntegrationRepo, table, id: :integer)

    assert %{command: :insert, rows: nil, num_rows: 2} =
             insert = insert_rows!(QuackDB.IntegrationRepo, table, [[1], [2]])

    assert insert.metadata[:duckdb_rows] == [[2]]
  end

  test "Ecto spatial helpers accept pinned Geo structs" do
    start_repo!()
    table = unique_table("quackdb_ecto_spatial")

    QuackDB.IntegrationRepo.query!(QuackDB.Spatial.load())

    QuackDB.IntegrationRepo.query!(
      QuackDB.DDL.create_table(table, [id: :integer, geom: :geometry], temporary: true)
    )

    point = %Geo.Point{coordinates: {1.0, 2.0}, srid: nil}

    QuackDB.IntegrationRepo.query!(
      QuackDB.DML.insert_into(table,
        id: 1,
        geom: {:expr, QuackDB.Spatial.geom_from_wkb(QuackDB.Geometry.from_geo!(point))}
      )
    )

    query =
      from(place in table,
        where: intersects(place.geom, ^point) and distance(place.geom, ^point) < 1,
        select: as_text(place.geom)
      )

    assert ["POINT (1 2)"] = QuackDB.IntegrationRepo.all(query)
  end

  test "DDL create_table supports CTAS from Ecto queries" do
    start_repo!()
    source = unique_table("quackdb_ecto_ctas_source")
    target = unique_table("quackdb_ecto_ctas_target")

    create_table!(QuackDB.IntegrationRepo, source, id: :integer, name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, source, [[1, "duck"], [2, "goose"]])

    query =
      from(event in source,
        where: event.id == 1,
        select: %{id: event.id, name: event.name}
      )

    QuackDB.IntegrationRepo.query!(QuackDB.DDL.create_table(target, as: query, temporary: true))

    assert %{rows: [[1, "duck"]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name FROM #{target} ORDER BY id")
  end

  test "Ecto type/2 casts execute against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_type_casts")

    create_table!(QuackDB.IntegrationRepo, table,
      id: :integer,
      score: :integer,
      occurred_at: :timestamp
    )

    insert_rows!(QuackDB.IntegrationRepo, table, [[1, 7, ~N[2024-01-02 03:04:05]]])

    query =
      from(event in table,
        where: type(event.id, :string) == ^"1" and type(^"10", :integer) > event.score,
        select: %{
          id_text: type(event.id, :string),
          score_decimal: type(event.score, :decimal),
          occurred_on: type(event.occurred_at, :date)
        }
      )

    assert [result] = QuackDB.IntegrationRepo.all(query)
    assert result.id_text == "1"
    assert Decimal.equal?(result.score_decimal, Decimal.new("7"))
    assert result.occurred_on == ~D[2024-01-02]
  end

  test "Ecto Repo.insert_all/3 inserts rows with generated SQL" do
    start_repo!()
    table = unique_table("quackdb_ecto_insert_all")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar)

    assert {2, nil} =
             QuackDB.IntegrationRepo.insert_all(table, [
               [id: 1, name: "duck"],
               [id: 2, name: "goose"]
             ])

    assert %{rows: [[1, "duck"], [2, "goose"]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name FROM #{table} ORDER BY id")
  end

  test "Ecto Repo.insert_all/3 supports on_conflict update" do
    start_repo!()
    table = unique_table("quackdb_ecto_insert_upsert")

    create_table!(QuackDB.IntegrationRepo, table, id: "INTEGER PRIMARY KEY", name: :varchar)

    assert {1, nil} = QuackDB.IntegrationRepo.insert_all(table, [[id: 1, name: "duck"]])

    assert {1, nil} =
             QuackDB.IntegrationRepo.insert_all(table, [[id: 1, name: "mallard"]],
               on_conflict: [set: [name: "mallard"]],
               conflict_target: [:id]
             )

    assert %{rows: [[1, "mallard"]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name FROM #{table} ORDER BY id")
  end

  test "Ecto Repo.insert_all/3 supports replacement upsert variants" do
    start_repo!()
    table = "keyed_events"

    drop_table!(QuackDB.IntegrationRepo, table)

    create_table!(QuackDB.IntegrationRepo, table,
      id: "INTEGER PRIMARY KEY",
      name: :varchar,
      score: :integer
    )

    assert {1, nil} =
             QuackDB.IntegrationRepo.insert_all(QuackDB.TestSchemas.KeyedEvent, [
               [id: 1, name: "duck", score: 10]
             ])

    assert {1, nil} =
             QuackDB.IntegrationRepo.insert_all(
               QuackDB.TestSchemas.KeyedEvent,
               [[id: 1, name: "mallard", score: 20]],
               on_conflict: {:replace, [:name]},
               conflict_target: [:id]
             )

    assert %{rows: [[1, "mallard", 10]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name, score FROM #{table} ORDER BY id")

    assert {1, nil} =
             QuackDB.IntegrationRepo.insert_all(
               QuackDB.TestSchemas.KeyedEvent,
               [[id: 1, name: "goose", score: 30]],
               on_conflict: {:replace_all_except, [:id]},
               conflict_target: [:id]
             )

    assert %{rows: [[1, "goose", 30]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name, score FROM #{table} ORDER BY id")
  end

  test "Ecto Repo.insert_all/3 supports on_conflict increment" do
    start_repo!()
    table = unique_table("quackdb_ecto_insert_upsert_inc")

    create_table!(QuackDB.IntegrationRepo, table, id: "INTEGER PRIMARY KEY", score: :integer)

    assert {1, nil} = QuackDB.IntegrationRepo.insert_all(table, [[id: 1, score: 10]])

    assert {1, nil} =
             QuackDB.IntegrationRepo.insert_all(table, [[id: 1, score: 1]],
               on_conflict: [inc: [score: 5]],
               conflict_target: [:id]
             )

    assert %{rows: [[1, 15]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, score FROM #{table} ORDER BY id")
  end

  test "Ecto Repo.insert_all/3 supports on_conflict nothing" do
    start_repo!()
    table = unique_table("quackdb_ecto_insert_conflict")

    create_table!(QuackDB.IntegrationRepo, table, id: "INTEGER PRIMARY KEY", name: :varchar)

    assert {1, nil} = QuackDB.IntegrationRepo.insert_all(table, [[id: 1, name: "duck"]])

    assert {0, nil} =
             QuackDB.IntegrationRepo.insert_all(table, [[id: 1, name: "goose"]],
               on_conflict: :nothing
             )

    assert %{rows: [[1, "duck"]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name FROM #{table} ORDER BY id")
  end

  test "Ecto Repo.update_all/3 updates rows" do
    start_repo!()
    table = unique_table("quackdb_ecto_update_all")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar, score: :integer)
    insert_rows!(QuackDB.IntegrationRepo, table, [[1, "duck", 10], [2, "goose", 20]])

    query = from(event in table, where: event.id == ^1)

    assert {1, nil} =
             QuackDB.IntegrationRepo.update_all(query, set: [name: "mallard"], inc: [score: 5])

    assert %{rows: [[1, "mallard", 15], [2, "goose", 20]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name, score FROM #{table} ORDER BY id")
  end

  test "Ecto Repo.update_all/3 updates rows with joins" do
    start_repo!()
    events = unique_table("quackdb_ecto_update_join_events")
    categories = unique_table("quackdb_ecto_update_join_categories")

    create_table!(QuackDB.IntegrationRepo, events,
      id: :integer,
      category_id: :integer,
      name: :varchar
    )

    create_table!(QuackDB.IntegrationRepo, categories, id: :integer, name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, events, [[1, 1, "old"], [2, 2, "old"]])
    insert_rows!(QuackDB.IntegrationRepo, categories, [[1, "duck"], [2, "goose"]])

    query =
      from(event in events,
        join: category in ^categories,
        on: category.id == event.category_id,
        where: category.name == ^"duck"
      )

    assert {1, nil} = QuackDB.IntegrationRepo.update_all(query, set: [name: "mallard"])

    assert %{rows: [[1, "mallard"], [2, "old"]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name FROM #{events} ORDER BY id")
  end

  test "Ecto Repo.delete_all/2 deletes rows" do
    start_repo!()
    table = unique_table("quackdb_ecto_delete_all")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, table, [[1, "duck"], [2, "goose"]])

    query = from(event in table, where: event.id == ^2)

    assert {1, nil} = QuackDB.IntegrationRepo.delete_all(query)

    assert %{rows: [[1, "duck"]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name FROM #{table} ORDER BY id")
  end

  test "Ecto Repo.delete_all/2 deletes rows with joins" do
    start_repo!()
    events = unique_table("quackdb_ecto_delete_join_events")
    categories = unique_table("quackdb_ecto_delete_join_categories")

    create_table!(QuackDB.IntegrationRepo, events,
      id: :integer,
      category_id: :integer,
      name: :varchar
    )

    create_table!(QuackDB.IntegrationRepo, categories, id: :integer, name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, events, [[1, 1, "duck"], [2, 2, "goose"]])
    insert_rows!(QuackDB.IntegrationRepo, categories, [[1, "birds"], [2, "mammals"]])

    query =
      from(event in events,
        join: category in ^categories,
        on: category.id == event.category_id,
        where: category.name == ^"mammals"
      )

    assert {1, nil} = QuackDB.IntegrationRepo.delete_all(query)

    assert %{rows: [[1, "duck"]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name FROM #{events} ORDER BY id")
  end

  test "Ecto Repo.insert_all/3 supports insert from query" do
    start_repo!()
    source = unique_table("quackdb_ecto_insert_source")
    target = unique_table("quackdb_ecto_insert_target")

    create_table!(QuackDB.IntegrationRepo, source, id: :integer, name: :varchar)
    create_table!(QuackDB.IntegrationRepo, target, id: :integer, name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, source, [[1, "duck"], [2, "goose"]])

    query =
      from(event in source,
        select: %{id: event.id + 10, name: event.name}
      )

    assert {2, nil} = QuackDB.IntegrationRepo.insert_all(target, query)

    assert %{rows: [[11, "duck"], [12, "goose"]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name FROM #{target} ORDER BY id")
  end

  test "Ecto Repo.insert_all/3 supports returning rows" do
    start_repo!()
    table = unique_table("quackdb_ecto_insert_returning")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar)

    assert {2, [%{id: 1}, %{id: 2}]} =
             QuackDB.IntegrationRepo.insert_all(
               table,
               [[id: 1, name: "duck"], [id: 2, name: "goose"]],
               returning: [:id]
             )
  end

  test "Ecto Repo.update/2 updates a primary-key schema changeset" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "keyed_events")

    create_table!(QuackDB.IntegrationRepo, "keyed_events",
      id: "INTEGER PRIMARY KEY",
      name: :varchar,
      score: :integer
    )

    insert_rows!(QuackDB.IntegrationRepo, "keyed_events", [[1, "duck", 10]])

    event = QuackDB.IntegrationRepo.get!(QuackDB.TestSchemas.KeyedEvent, 1)
    changeset = Ecto.Changeset.change(event, name: "mallard", score: 15)

    assert {:ok, %QuackDB.TestSchemas.KeyedEvent{id: 1, name: "mallard", score: 15}} =
             QuackDB.IntegrationRepo.update(changeset)

    assert %{rows: [[1, "mallard", 15]]} =
             QuackDB.IntegrationRepo.query!(
               "SELECT id, name, score FROM keyed_events ORDER BY id"
             )
  end

  test "Ecto Repo.delete/2 deletes a primary-key schema struct" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "keyed_events")

    create_table!(QuackDB.IntegrationRepo, "keyed_events",
      id: "INTEGER PRIMARY KEY",
      name: :varchar,
      score: :integer
    )

    insert_rows!(QuackDB.IntegrationRepo, "keyed_events", [[1, "duck", 10]])

    event = QuackDB.IntegrationRepo.get!(QuackDB.TestSchemas.KeyedEvent, 1)

    assert {:ok, %QuackDB.TestSchemas.KeyedEvent{id: 1, name: "duck", score: 10}} =
             QuackDB.IntegrationRepo.delete(event)

    assert %{rows: [[0]]} = QuackDB.IntegrationRepo.query!("SELECT count(*) FROM keyed_events")
  end

  test "Ecto Repo.explain/3 returns a DuckDB query plan" do
    start_repo!()
    table = unique_table("quackdb_ecto_explain")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar)

    plan =
      Ecto.Adapters.SQL.explain(
        QuackDB.IntegrationRepo,
        :all,
        from(event in table, where: event.id == ^1, select: event.name),
        wrap_in_transaction: false
      )

    assert {:ok, plan} = plan
    assert plan =~ "EMPTY_RESULT"
  end

  test "Ecto Repo.insert/2 supports on_conflict nothing" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "keyed_events")

    create_table!(QuackDB.IntegrationRepo, "keyed_events",
      id: "INTEGER PRIMARY KEY",
      name: :varchar,
      score: :integer
    )

    insert_rows!(QuackDB.IntegrationRepo, "keyed_events", [[1, "duck", 10]])

    event = %QuackDB.TestSchemas.KeyedEvent{id: 1, name: "goose", score: 20}

    assert {:ok, %QuackDB.TestSchemas.KeyedEvent{id: 1, name: "goose", score: 20}} =
             QuackDB.IntegrationRepo.insert(event,
               on_conflict: :nothing,
               conflict_target: [:id]
             )

    assert %{rows: [[1, "duck", 10]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name, score FROM keyed_events")
  end

  test "Ecto Repo.insert/2 supports on_conflict update" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "keyed_events")

    create_table!(QuackDB.IntegrationRepo, "keyed_events",
      id: "INTEGER PRIMARY KEY",
      name: :varchar,
      score: :integer
    )

    insert_rows!(QuackDB.IntegrationRepo, "keyed_events", [[1, "duck", 10]])

    event = %QuackDB.TestSchemas.KeyedEvent{id: 1, name: "goose", score: 20}

    assert {:ok, %QuackDB.TestSchemas.KeyedEvent{id: 1, name: "goose", score: 20}} =
             QuackDB.IntegrationRepo.insert(event,
               on_conflict: [set: [name: "mallard"]],
               conflict_target: [:id]
             )

    assert %{rows: [[1, "mallard", 10]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name, score FROM keyed_events")
  end

  test "Ecto Repo.insert/2 inserts a schema struct" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "events")
    create_table!(QuackDB.IntegrationRepo, "events", id: :integer, name: :varchar)

    event = %QuackDB.TestSchemas.Event{id: 1, name: "duck"}

    assert {:ok, %QuackDB.TestSchemas.Event{id: 1, name: "duck"}} =
             QuackDB.IntegrationRepo.insert(event)

    assert %{rows: [[1, "duck"]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name FROM events ORDER BY id")
  end

  test "Ecto writes work inside transactions" do
    start_repo!()
    table = unique_table("quackdb_ecto_transaction_writes")

    create_table!(QuackDB.IntegrationRepo, table,
      id: "INTEGER PRIMARY KEY",
      name: :varchar,
      score: :integer
    )

    assert {:ok, :done} =
             QuackDB.IntegrationRepo.transaction(fn ->
               assert {1, nil} =
                        QuackDB.IntegrationRepo.insert_all(table, [
                          [id: 1, name: "duck", score: 10]
                        ])

               assert {1, nil} =
                        QuackDB.IntegrationRepo.insert_all(
                          table,
                          [[id: 1, name: "mallard", score: 0]],
                          on_conflict: [set: [name: "mallard"]],
                          conflict_target: [:id]
                        )

               query = from(event in table, where: event.id == ^1)
               assert {1, nil} = QuackDB.IntegrationRepo.update_all(query, inc: [score: 5])

               assert {1, nil} =
                        QuackDB.IntegrationRepo.insert_all(
                          table,
                          [[id: 2, name: "goose", score: 20]],
                          insert_method: :append
                        )

               :done
             end)

    assert %{rows: [[1, "mallard", 15], [2, "goose", 20]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name, score FROM #{table} ORDER BY id")
  end

  test "Ecto Repo.insert_all/3 can use Quack append explicitly" do
    start_repo!()
    table = unique_table("quackdb_ecto_append_all")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar)

    assert {3, nil} =
             QuackDB.IntegrationRepo.insert_all(
               table,
               [[id: 1, name: "duck"], [id: 2, name: "goose"], [id: 3, name: "swan"]],
               insert_method: :append,
               chunk_every: 2
             )

    assert %{rows: [[1, "duck"], [2, "goose"], [3, "swan"]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name FROM #{table} ORDER BY id")
  end

  test "Ecto append insert_all can omit defaulted schema columns" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "typed_events")

    create_table!(QuackDB.IntegrationRepo, "typed_events",
      id: "INTEGER DEFAULT 42",
      event_date: :date,
      tags: {:list, :varchar}
    )

    assert {1, [%{id: 42}]} =
             QuackDB.IntegrationRepo.insert_all(
               QuackDB.TestSchemas.TypedEvent,
               [[event_date: nil, tags: nil]],
               insert_method: :append,
               returning: [:id]
             )

    assert %{rows: [[42, nil, nil]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, event_date, tags FROM typed_events")
  end

  test "Ecto append returning works inside transactions" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "typed_events")

    create_table!(QuackDB.IntegrationRepo, "typed_events",
      id: "INTEGER DEFAULT 42",
      event_date: :date,
      tags: {:list, :varchar}
    )

    assert {:ok, {1, [%{id: 42}]}} =
             QuackDB.IntegrationRepo.transaction(fn ->
               QuackDB.IntegrationRepo.insert_all(
                 QuackDB.TestSchemas.TypedEvent,
                 [[event_date: nil, tags: nil]],
                 insert_method: :append,
                 returning: [:id]
               )
             end)

    assert %{rows: [[42, nil, nil]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, event_date, tags FROM typed_events")
  end

  test "Ecto Repo.all/2 executes simple read-only queries against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_all")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, table, [[1, "duck"], [2, "goose"]])

    query =
      from(event in table,
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    assert [%{id: 2, name: "goose"}] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto Repo.get!/2 loads schema structs with renamed field sources" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "renamed_events")
    create_table!(QuackDB.IntegrationRepo, "renamed_events", id: :integer, event_name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, "renamed_events", [[1, "duck"]])

    assert %QuackDB.TestSchemas.RenamedEvent{id: 1, name: "duck"} =
             QuackDB.IntegrationRepo.get_by!(QuackDB.TestSchemas.RenamedEvent, id: 1)
  end

  test "Ecto Repo.get!/2 loads full schema structs" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "keyed_events")

    create_table!(QuackDB.IntegrationRepo, "keyed_events",
      id: "INTEGER PRIMARY KEY",
      name: :varchar,
      score: :integer
    )

    insert_rows!(QuackDB.IntegrationRepo, "keyed_events", [[1, "duck", 10]])

    assert %QuackDB.TestSchemas.KeyedEvent{id: 1, name: "duck", score: 10} =
             QuackDB.IntegrationRepo.get!(QuackDB.TestSchemas.KeyedEvent, 1)
  end

  test "Ecto Repo.one/2 executes singleton read queries against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_one")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, table, [[1, "duck"], [2, "goose"]])

    query =
      from(event in table,
        where: event.id == 1,
        select: event.name
      )

    assert "duck" = QuackDB.IntegrationRepo.one(query)
  end

  test "Ecto Repo.exists?/2 executes existence queries against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_exists")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, table, [[1, "duck"], [2, "goose"]])

    matching_query = from(event in table, where: event.name == "duck")
    missing_query = from(event in table, where: event.name == "swan")

    assert QuackDB.IntegrationRepo.exists?(matching_query)
    refute QuackDB.IntegrationRepo.exists?(missing_query)
  end

  test "Ecto Repo.aggregate/4 executes aggregate queries against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_aggregate")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, score: :integer)
    insert_rows!(QuackDB.IntegrationRepo, table, [[1, 10], [2, 20], [3, 30]])

    query = from(event in table, where: event.score >= 20)

    assert 2 = QuackDB.IntegrationRepo.aggregate(query, :count, :id)
    assert 50 = QuackDB.IntegrationRepo.aggregate(query, :sum, :score)
  end

  test "Ecto Repo.all/2 supports schema-backed sources against a real Quack server" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "events")

    create_table!(QuackDB.IntegrationRepo, "events",
      id: :integer,
      name: :varchar,
      score: :integer,
      category_id: :integer
    )

    insert_rows!(QuackDB.IntegrationRepo, "events", [[1, "duck", 10, 1], [2, "goose", 20, 1]])

    query =
      from(event in QuackDB.TestSchemas.Event,
        where: event.score > 10,
        select: %{id: event.id, name: event.name, score: event.score}
      )

    assert [%{id: 2, name: "goose", score: 20}] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto Repo.all/2 supports schema-backed joins against a real Quack server" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "events")
    drop_table!(QuackDB.IntegrationRepo, "categories")

    create_table!(QuackDB.IntegrationRepo, "events",
      id: :integer,
      name: :varchar,
      score: :integer,
      category_id: :integer
    )

    create_table!(QuackDB.IntegrationRepo, "categories", id: :integer, name: :varchar)

    insert_rows!(QuackDB.IntegrationRepo, "events", [[1, "duck", 10, 1], [2, "goose", 20, 2]])
    insert_rows!(QuackDB.IntegrationRepo, "categories", [[1, "bird"], [2, "other"]])

    query =
      from(event in QuackDB.TestSchemas.Event,
        join: category in QuackDB.TestSchemas.Category,
        on: event.category_id == category.id,
        order_by: [asc: event.id],
        select: %{event: event.name, category: category.name}
      )

    assert [
             %{event: "duck", category: "bird"},
             %{event: "goose", category: "other"}
           ] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto schema parameters preserve common DuckDB scalar types" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "typed_events")

    create_table!(QuackDB.IntegrationRepo, "typed_events",
      id: :integer,
      amount: {:decimal, 8, 2},
      event_date: :date,
      event_time: :time,
      occurred_at: :timestamp,
      occurred_tz: :timestamp_tz,
      tags: {:list, :varchar}
    )

    row = [
      id: 1,
      amount: Decimal.new("12.34"),
      event_date: ~D[2026-05-26],
      event_time: ~T[12:34:56],
      occurred_at: ~N[2026-05-26 12:34:56],
      occurred_tz: ~U[2026-05-26 12:34:56Z],
      tags: ["duck", "analytics"]
    ]

    assert {1, nil} = QuackDB.IntegrationRepo.insert_all(QuackDB.TestSchemas.TypedEvent, [row])

    query =
      from(event in QuackDB.TestSchemas.TypedEvent,
        where:
          event.amount == ^Decimal.new("12.34") and
            event.event_date == ^~D[2026-05-26] and
            event.event_time == ^~T[12:34:56] and
            event.occurred_at == ^~N[2026-05-26 12:34:56] and
            event.occurred_tz == ^~U[2026-05-26 12:34:56Z],
        select: event
      )

    assert [
             %QuackDB.TestSchemas.TypedEvent{
               id: 1,
               amount: amount,
               event_date: ~D[2026-05-26],
               event_time: ~T[12:34:56],
               occurred_at: ~N[2026-05-26 12:34:56],
               tags: ["duck", "analytics"]
             }
           ] = QuackDB.IntegrationRepo.all(query)

    assert Decimal.equal?(amount, Decimal.new("12.34"))
  end

  test "Ecto schema parameters preserve binary_id and binary values" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "binary_events")

    create_table!(QuackDB.IntegrationRepo, "binary_events",
      id: :uuid,
      payload: :blob
    )

    uuid = Ecto.UUID.generate()
    payload = <<0, 1, 2, 255>>

    assert {1, nil} =
             QuackDB.IntegrationRepo.insert_all(QuackDB.TestSchemas.BinaryEvent, [
               [id: uuid, payload: payload]
             ])

    query =
      from(event in QuackDB.TestSchemas.BinaryEvent,
        where: event.id == ^uuid and event.payload == ^payload,
        select: event
      )

    assert [%QuackDB.TestSchemas.BinaryEvent{id: ^uuid, payload: ^payload}] =
             QuackDB.IntegrationRepo.all(query)

    id_query = from(event in QuackDB.TestSchemas.BinaryEvent, select: event.id)
    map_query = from(event in QuackDB.TestSchemas.BinaryEvent, select: %{id: event.id})

    assert [^uuid] = QuackDB.IntegrationRepo.all(id_query)
    assert [%{id: ^uuid}] = QuackDB.IntegrationRepo.all(map_query)
  end

  test "Ecto schema parameters preserve renamed binary_id source fields" do
    start_repo!()

    drop_table!(QuackDB.IntegrationRepo, "renamed_binary_events")

    create_table!(QuackDB.IntegrationRepo, "renamed_binary_events",
      event_uuid: :uuid,
      payload: :blob
    )

    uuid = Ecto.UUID.generate()
    payload = <<3, 2, 1, 0>>

    assert {1, nil} =
             QuackDB.IntegrationRepo.insert_all(QuackDB.TestSchemas.RenamedBinaryEvent, [
               [id: uuid, payload: payload]
             ])

    full_query = from(event in QuackDB.TestSchemas.RenamedBinaryEvent, select: event)
    map_query = from(event in QuackDB.TestSchemas.RenamedBinaryEvent, select: %{id: event.id})

    assert [%QuackDB.TestSchemas.RenamedBinaryEvent{id: ^uuid, payload: ^payload}] =
             QuackDB.IntegrationRepo.all(full_query)

    assert [%{id: ^uuid}] = QuackDB.IntegrationRepo.all(map_query)
  end

  test "Ecto raw query parameters preserve UUID and blob values" do
    start_repo!()
    uuid = Ecto.UUID.generate()
    blob = <<0, 1, 2, 255>>

    assert %{rows: [[^uuid, ^blob]]} =
             QuackDB.IntegrationRepo.query!(
               "SELECT ?::UUID::VARCHAR, ?::BLOB",
               [{:binary_id, uuid}, {:binary, blob}]
             )
  end

  test "Ecto raw query parameters preserve interval values" do
    start_repo!()

    interval = QuackDB.Interval.new(2, 3, 4_000)

    assert %{rows: [[2, 3, 4_000]]} =
             QuackDB.IntegrationRepo.query!(
               "SELECT datepart('month', ?), datepart('day', ?), datepart('microsecond', ?)",
               [interval, interval, interval]
             )
  end

  test "Ecto Repo.all/2 supports pinned parameters against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_params")
    name = "duck"

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, table, [[1, "duck"], [2, "goose"]])

    query =
      from(event in table,
        where: event.name == ^name,
        select: %{id: event.id, name: event.name}
      )

    assert [%{id: 1, name: "duck"}] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto Repo.all/2 supports aggregates and common predicates against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_agg")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer, name: :varchar)
    insert_rows!(QuackDB.IntegrationRepo, table, [[1, "duck"], [2, "goose"], [3, nil]])

    query =
      from(event in table,
        where: like(event.name, "d%") and not is_nil(event.name),
        select: %{count: count(event.id)}
      )

    assert [%{count: 1}] = QuackDB.IntegrationRepo.all(query)

    fragment_query =
      from(event in table,
        where: event.id == 1,
        select: %{upper_name: fragment("upper(?)", event.name)}
      )

    assert [%{upper_name: "DUCK"}] = QuackDB.IntegrationRepo.all(fragment_query)
  end

  test "Ecto Repo.all/2 supports analytical CTEs and windows against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_window")

    create_table!(QuackDB.IntegrationRepo, table,
      id: :integer,
      category: :varchar,
      score: :integer
    )

    insert_rows!(QuackDB.IntegrationRepo, table, [
      [1, "a", 10],
      [2, "a", 20],
      [3, "b", 15],
      [4, "b", 5]
    ])

    high_scores =
      from(event in table,
        where: event.score >= 10,
        select: %{id: event.id, category: event.category, score: event.score}
      )

    query =
      from(event in "high_scores",
        windows: [by_category: [partition_by: event.category, order_by: [desc: event.score]]],
        order_by: [asc: event.category, asc: event.id],
        select: %{
          category: event.category,
          row_number: over(row_number(), :by_category),
          running_score: over(sum(event.score), :by_category)
        }
      )
      |> with_cte("high_scores", as: ^high_scores)

    assert [
             %{category: "a", row_number: 2, running_score: 30},
             %{category: "a", row_number: 1, running_score: 20},
             %{category: "b", row_number: 1, running_score: 15}
           ] = QuackDB.IntegrationRepo.all(query)
  end
end
