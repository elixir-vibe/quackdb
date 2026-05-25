defmodule QuackDB.Integration.EctoAnalyticsTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.Ecto.Analytics
  import QuackDB.QuackServerCase

  @moduletag :integration

  test "analytical aggregate helpers execute against a real Quack server" do
    start_repo!()
    table = "quackdb_ecto_analytics_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!(
      QuackDB.DDL.create_table(
        table,
        [category: :varchar, name: :varchar, score: :integer],
        temporary: true
      )
    )

    QuackDB.IntegrationRepo.query!(
      "INSERT INTO #{table} VALUES ('a', 'duck', 10), ('a', 'goose', 20), ('a', 'swan', 30), ('b', 'salmon', 5)"
    )

    query =
      from(event in table,
        group_by: event.category,
        order_by: [asc: event.category],
        select: %{
          category: event.category,
          median_score: median(event.score),
          p95_score: quantile_cont(event.score, 0.95),
          scores: duckdb_list(event.score),
          names: string_agg(event.name, ","),
          best_name: arg_max(event.name, event.score),
          worst_name: arg_min(event.name, event.score)
        }
      )

    assert [
             %{
               category: "a",
               median_score: 20.0,
               p95_score: 29.0,
               scores: [10, 20, 30],
               names: "duck,goose,swan",
               best_name: "swan",
               worst_name: "duck"
             },
             %{
               category: "b",
               median_score: 5.0,
               p95_score: 5.0,
               scores: [5],
               names: "salmon",
               best_name: "salmon",
               worst_name: "salmon"
             }
           ] = QuackDB.IntegrationRepo.all(query)
  end

  test "JSON and time-series helpers execute against a real Quack server" do
    start_repo!()
    table = "quackdb_ecto_json_time_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!(
      QuackDB.DDL.create_table(table, [payload: :json, occurred_at: :timestamp], temporary: true)
    )

    QuackDB.IntegrationRepo.query!("""
    INSERT INTO #{table} VALUES
      ('{"name":"duck","kind":"bird","score":10}', TIMESTAMP '2024-01-02 03:04:05'),
      ('{"name":"salmon","kind":"fish","score":5}', TIMESTAMP '2024-01-03 04:05:06')
    """)

    query =
      from(event in table,
        where: json_extract_string(event.payload, "$.kind") == "bird",
        select: %{
          name: json_extract_string(event.payload, "$.name"),
          score: json_extract(event.payload, "$.score"),
          day: date_trunc("day", event.occurred_at),
          bucket: time_bucket("1 day", event.occurred_at)
        }
      )

    assert [
             %{
               name: "duck",
               score: "10",
               day: ~N[2024-01-02 00:00:00.000000],
               bucket: ~N[2024-01-02 00:00:00.000000]
             }
           ] = QuackDB.IntegrationRepo.all(query)
  end
end
