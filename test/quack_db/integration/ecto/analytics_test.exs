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
              event.score >= 10 and event.score <= 19 -> "high"
              true -> "normal"
            end,
          hour: date_part(:hour, event.occurred_at),
          safe_score:
            case_when do
              event.score == 0 -> nil
              true -> event.score
            end,
          score_or_zero: coalesce(event.score, 0),
          score_stddev: over(stddev(event.score), []),
          score_variance: over(variance(event.score), []),
          score_mode: over(mode(event.score), []),
          score_entropy: over(entropy(event.score), []),
          score_mad: over(mad(event.score), []),
          rolling_score:
            over(sum(event.score),
              order_by: [asc: event.id],
              frame: fragment("ROWS BETWEEN 1 PRECEDING AND CURRENT ROW")
            )
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

    assert [
             %{
               tier: "high",
               hour: 3,
               safe_score: 10,
               score_or_zero: 10,
               score_stddev: stddev,
               score_variance: variance,
               score_mode: 10,
               score_entropy: entropy,
               score_mad: mad,
               rolling_score: 10
             },
             _second
           ] =
             QuackDB.IntegrationRepo.all(ConditionalQueries.summary(table))

    assert is_float(stddev)
    assert is_float(variance)
    assert is_float(entropy)
    assert is_number(mad)
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
          scores: list(event.score),
          weighted_score: weighted_avg(event.score, event.score),
          score_geometric_mean: geometric_mean(event.score),
          distinct_names: count(event.name, :distinct),
          names: string_agg(event.name, ","),
          best_name: arg_max(event.name, event.score),
          worst_name: arg_min(event.name, event.score),
          histogram: histogram(event.score),
          exact_histogram: histogram_exact(event.score, ^[10, 20, 30])
        }
      )

    assert [
             %{
               category: "a",
               median_score: 20.0,
               p95_score: 29.0,
               scores: [10, 20, 30],
               weighted_score: weighted_a,
               score_geometric_mean: geometric_mean_a,
               distinct_names: 3,
               names: "duck,goose,swan",
               best_name: "swan",
               worst_name: "duck",
               histogram: %{10 => 1, 20 => 1, 30 => 1},
               exact_histogram: %{10 => 1, 20 => 1, 30 => 1}
             },
             %{
               category: "b",
               median_score: 5.0,
               p95_score: 5.0,
               scores: [5],
               weighted_score: 5.0,
               score_geometric_mean: geometric_mean_b,
               distinct_names: 1,
               names: "salmon",
               best_name: "salmon",
               worst_name: "salmon",
               histogram: %{5 => 1},
               exact_histogram: %{10 => 0, 20 => 0, 30 => 0, 2_147_483_647 => 1}
             }
           ] = QuackDB.IntegrationRepo.all(query)

    assert_in_delta weighted_a, 23.333333333333332, 0.000001
    assert_in_delta geometric_mean_a, 18.171205928321395, 0.000001
    assert_in_delta geometric_mean_b, 5.0, 0.000001
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
