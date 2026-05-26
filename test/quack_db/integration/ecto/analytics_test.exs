defmodule QuackDB.Integration.Ecto.AnalyticsTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.Ecto.Analytics
  import QuackDB.QuackServerCase
  import QuackDB.TestHelper

  @moduletag :integration

  defmodule ConditionalQueries do
    use QuackDB.Ecto

    def summary(table) do
      from(event in table,
        order_by: event.id,
        select: %{
          tier:
            case_when do
              event.score >= 20 -> "very high"
              event.score >= 10 -> "high"
              true -> "normal"
            end,
          hour: date_part("hour", event.occurred_at),
          safe_score:
            case_when do
              event.score == 0 -> nil
              true -> event.score
            end,
          score_stddev: over(stddev(event.score), [])
        }
      )
    end
  end

  test "conditional and statistical helpers execute against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_conditionals")

    create_table!(QuackDB.IntegrationRepo, table,
      id: :integer,
      score: :integer,
      occurred_at: :timestamp
    )

    insert_rows!(QuackDB.IntegrationRepo, table, [
      [1, 10, ~N[2024-01-02 03:04:05]],
      [2, 20, ~N[2024-01-02 04:05:06]]
    ])

    assert [%{tier: "high", hour: 3, safe_score: 10, score_stddev: stddev}, _second] =
             QuackDB.IntegrationRepo.all(ConditionalQueries.summary(table))

    assert is_float(stddev)
  end

  test "analytical aggregate helpers execute against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_analytics")

    create_table!(QuackDB.IntegrationRepo, table,
      category: :varchar,
      name: :varchar,
      score: :integer
    )

    insert_rows!(QuackDB.IntegrationRepo, table, [
      ["a", "duck", 10],
      ["a", "goose", 20],
      ["a", "swan", 30],
      ["b", "salmon", 5]
    ])

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
    table = unique_table("quackdb_ecto_json_time")

    create_table!(QuackDB.IntegrationRepo, table, payload: :json, occurred_at: :timestamp)

    insert_rows!(QuackDB.IntegrationRepo, table, [
      [~s({"name":"duck","kind":"bird","score":10,"active":true}), ~N[2024-01-02 03:04:05]],
      [~s({"name":"salmon","kind":"fish","score":5,"active":false}), ~N[2024-01-03 04:05:06]]
    ])

    interval = Duration.new!(minute: 15)
    origin = ~N[2024-01-01 00:00:00]
    offset = Duration.new!(minute: 5)

    query =
      from(event in table,
        where: json_extract_string(event.payload, "$.kind") == "bird",
        select: %{
          name: event.payload["name"],
          high_score: type(event.payload["score"], :integer) > 5,
          active: type(event.payload["active"], :boolean),
          score: json_extract(event.payload, [:score]),
          has_name: json_exists(event.payload, [:name]),
          contains_name: json_contains(event.payload, ^{:json, %{name: "duck"}}),
          day: date_trunc("day", event.occurred_at),
          bucket: time_bucket("1 day", event.occurred_at),
          fifteen_minute_bucket: time_bucket(^interval, event.occurred_at),
          origin_bucket: time_bucket(^interval, event.occurred_at, origin: ^origin),
          offset_bucket: time_bucket(^interval, event.occurred_at, offset: ^offset)
        }
      )

    assert [
             %{
               name: "duck",
               high_score: true,
               active: true,
               score: "10",
               has_name: true,
               contains_name: true,
               day: ~N[2024-01-02 00:00:00.000000],
               bucket: ~N[2024-01-02 00:00:00.000000],
               fifteen_minute_bucket: ~N[2024-01-02 03:00:00.000000],
               origin_bucket: ~N[2024-01-02 03:00:00.000000],
               offset_bucket: ~N[2024-01-02 02:50:00.000000]
             }
           ] = QuackDB.IntegrationRepo.all(query)
  end
end
