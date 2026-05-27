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
          score_favg: over(favg(event.score), []),
          score_fsum: over(fsum(event.score), []),
          score_product: over(product(event.score), []),
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
               score_favg: favg,
               score_fsum: fsum,
               score_product: product,
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
    assert favg == 15.0
    assert fsum == 30.0
    assert product == 200.0
    assert is_float(entropy)
    assert is_number(mad)
  end

  test "summarize profiles Ecto queryables through the repo" do
    start_repo!()
    table = unique_table("quackdb_ecto_summarize")

    create_table!(QuackDB.IntegrationRepo, table,
      category: :varchar,
      score: :integer
    )

    insert_rows!(QuackDB.IntegrationRepo, table, [
      ["a", 10],
      ["a", 20],
      ["b", 30]
    ])

    query =
      from(event in table,
        where: event.score > ^10,
        select: %{category: event.category, score: event.score}
      )

    assert {:ok, result} = summarize(QuackDB.IntegrationRepo, query)
    assert %{columns: columns, rows: rows} = result
    assert "column_name" in columns
    assert Enum.any?(rows, fn [name | _rest] -> name == "score" end)

    assert %{rows: bang_rows} = summarize!(QuackDB.IntegrationRepo, :all, query)

    assert length(bang_rows) == length(rows)
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

  test "expanded aggregate helpers execute against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_expanded_analytics")

    create_table!(QuackDB.IntegrationRepo, table,
      category: :varchar,
      name: :varchar,
      score: :integer,
      weight: :integer,
      active: :boolean,
      flags: :integer
    )

    insert_rows!(QuackDB.IntegrationRepo, table, [
      ["a", "duck", 10, 1, true, 7],
      ["a", "goose", 20, 2, true, 3],
      ["a", "swan", 30, 3, false, 1]
    ])

    query =
      from(event in table,
        select: %{
          approximate_names: approx_count_distinct(event.name),
          approximate_median: approx_quantile(event.score, 0.5),
          top_scores: approx_top_k(event.score, 2),
          any_name: any_value(event.name),
          all_active: bool_and(event.active),
          any_active: bool_or(event.active),
          flags_and: band(event.flags),
          flags_or: bor(event.flags),
          flags_xor: bxor(event.flags),
          bit_positions: bitstring_agg(event.score),
          bit_range: bitstring_agg(event.score, 0, 32),
          kurtosis_population: kurtosis_pop(event.score),
          stddev_population: stddev_pop(event.score),
          variance_population: var_pop(event.score),
          variance_sample: var_samp(event.score),
          reservoir_median: reservoir_quantile(event.score, 0.5),
          reservoir_sampled: reservoir_quantile(event.score, 0.5, 128),
          regression_count: regr_count(event.weight, event.score),
          regression_r2: regr_r2(event.weight, event.score),
          regression_sxx: regr_sxx(event.weight, event.score),
          regression_sxy: regr_sxy(event.weight, event.score),
          regression_syy: regr_syy(event.weight, event.score)
        }
      )

    assert [row] = QuackDB.IntegrationRepo.all(query)

    assert row.approximate_names >= 1
    assert row.approximate_median == 20
    assert row.top_scores == [10, 20]
    assert row.any_name in ["duck", "goose", "swan"]
    assert row.all_active == false
    assert row.any_active == true
    assert row.flags_and == 1
    assert row.flags_or == 7
    assert row.flags_xor == 5
    assert is_binary(row.bit_positions)
    assert is_binary(row.bit_range)
    assert is_float(row.kurtosis_population)
    assert_in_delta row.stddev_population, 8.16496580927726, 0.000001
    assert_in_delta row.variance_population, 66.66666666666667, 0.000001
    assert_in_delta row.variance_sample, 100.0, 0.000001
    assert row.reservoir_median == 20
    assert row.reservoir_sampled == 20
    assert row.regression_count == 3
    assert_in_delta row.regression_r2, 1.0, 0.000001
    assert_in_delta row.regression_sxx, 200.0, 0.000001
    assert_in_delta row.regression_sxy, 20.0, 0.000001
    assert_in_delta row.regression_syy, 2.0, 0.000001
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
