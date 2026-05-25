defmodule QuackDB.Integration.EctoQueryTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase

  @moduletag :integration

  test "Ecto Repo.query/3 works against a real Quack server" do
    start_repo!()

    assert {:ok, %{columns: ["n"], rows: [[1]], num_rows: 1, command: :select}} =
             QuackDB.IntegrationRepo.query("SELECT 1 AS n")

    table = "quackdb_ecto_#{System.unique_integer([:positive])}"

    assert {:ok, %{command: :create, rows: nil, num_rows: 0}} =
             QuackDB.IntegrationRepo.query("CREATE TEMP TABLE #{table}(id INTEGER)")

    assert {:ok, %{command: :insert, rows: nil, num_rows: 2} = insert} =
             QuackDB.IntegrationRepo.query("INSERT INTO #{table} VALUES (1), (2)")

    assert insert.metadata[:duckdb_rows] == [[2]]
  end

  test "Ecto Repo.all/2 executes simple read-only queries against a real Quack server" do
    start_repo!()
    table = "quackdb_ecto_all_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER, name VARCHAR)")
    QuackDB.IntegrationRepo.query!("INSERT INTO #{table} VALUES (1, 'duck'), (2, 'goose')")

    query =
      from(event in table,
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    assert [%{id: 2, name: "goose"}] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto Repo.all/2 supports pinned parameters against a real Quack server" do
    start_repo!()
    table = "quackdb_ecto_params_#{System.unique_integer([:positive])}"
    name = "duck"

    QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER, name VARCHAR)")
    QuackDB.IntegrationRepo.query!("INSERT INTO #{table} VALUES (1, 'duck'), (2, 'goose')")

    query =
      from(event in table,
        where: event.name == ^name,
        select: %{id: event.id, name: event.name}
      )

    assert [%{id: 1, name: "duck"}] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto Repo.all/2 supports aggregates and common predicates against a real Quack server" do
    start_repo!()
    table = "quackdb_ecto_agg_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER, name VARCHAR)")

    QuackDB.IntegrationRepo.query!(
      "INSERT INTO #{table} VALUES (1, 'duck'), (2, 'goose'), (3, NULL)"
    )

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
    table = "quackdb_ecto_window_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!(
      "CREATE TEMP TABLE #{table}(id INTEGER, category VARCHAR, score INTEGER)"
    )

    QuackDB.IntegrationRepo.query!(
      "INSERT INTO #{table} VALUES (1, 'a', 10), (2, 'a', 20), (3, 'b', 15), (4, 'b', 5)"
    )

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
