defmodule QuackDB.Integration.Ecto.SourceAnalyticsTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase
  import QuackDB.TestHelper

  @moduletag :integration

  test "Ecto aggregates over CSV source helpers against a real Quack server" do
    start_repo!()

    source = csv_events_source!()

    query =
      from(event in source,
        group_by: event.category,
        order_by: [asc: event.category],
        select: %{
          category: event.category,
          total_score: sum(event.score),
          count: count(event.name)
        }
      )

    assert [
             %{category: "a", total_score: 30, count: 2},
             %{category: "b", total_score: 5, count: 1}
           ] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto windows over CSV source helpers against a real Quack server" do
    start_repo!()

    source = csv_events_source!()

    query =
      from(event in source,
        windows: [by_category: [partition_by: event.category, order_by: [desc: event.score]]],
        order_by: [asc: event.category, desc: event.score],
        select: %{
          category: event.category,
          name: event.name,
          score: event.score,
          rank: over(rank(), :by_category)
        }
      )

    assert [
             %{category: "a", name: "goose", score: 20, rank: 1},
             %{category: "a", name: "duck", score: 10, rank: 2},
             %{category: "b", name: "swan", score: 5, rank: 1}
           ] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto fragments run DuckDB analytical functions against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_analytics_fragments")

    create_table!(QuackDB.IntegrationRepo, table, category: :varchar, score: :integer)
    insert_rows!(QuackDB.IntegrationRepo, table, [["a", 10], ["a", 20], ["a", 30], ["b", 5]])

    query =
      from(event in table,
        group_by: event.category,
        order_by: [asc: event.category],
        select: %{
          category: event.category,
          median_score: fragment("median(?)", event.score),
          p50_score: fragment("quantile_cont(?, 0.5)", event.score),
          scores: fragment("list(?)", event.score)
        }
      )

    assert [
             %{category: "a", median_score: 20.0, p50_score: 20.0, scores: [10, 20, 30]},
             %{category: "b", median_score: 5.0, p50_score: 5.0, scores: [5]}
           ] = QuackDB.IntegrationRepo.all(query)
  end

  defp csv_events_source! do
    csv_source!("category,name,score
a,duck,10
a,goose,20
b,swan,5
")
  end
end
