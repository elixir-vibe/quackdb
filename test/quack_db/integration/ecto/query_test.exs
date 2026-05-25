defmodule QuackDB.Integration.Ecto.QueryTest do
  use ExUnit.Case, async: false

  import Ecto.Query
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
