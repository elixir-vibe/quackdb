defmodule QuackDB.Ecto.AnalyticsTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import QuackDB.Ecto.Analytics
  import QuackDB.Ecto.Conditionals

  test "builds date, null, and statistical analytical expressions" do
    query =
      from(event in "events",
        select: %{
          hour: date_part(:hour, event.occurred_at),
          day: date_trunc(:day, event.occurred_at),
          normalized_score:
            case_when do
              event.score >= 50 and event.score <= 90 -> "range"
              event.score == 0 -> nil
              true -> event.score
            end,
          score_stddev: stddev(event.score),
          score_variance: variance(event.score),
          score_mode: mode(event.score),
          weighted_score: weighted_avg(event.score, event.duration_ms),
          score_skewness: skewness(event.score),
          score_kurtosis: kurtosis(event.score),
          score_sem: sem(event.score),
          score_geometric_mean: geometric_mean(event.score),
          score_correlation: corr(event.score, event.duration_ms),
          score_covar_pop: covar_pop(event.score, event.duration_ms),
          score_covar_samp: covar_samp(event.score, event.duration_ms),
          score_slope: regr_slope(event.duration_ms, event.score),
          score_intercept: regr_intercept(event.duration_ms, event.score),
          score_entropy: entropy(event.score),
          score_mad: mad(event.score),
          score_histogram: histogram(event.score),
          exact_histogram: histogram_exact(event.score, ^[1, 2, 3]),
          bins: equi_width_bins(0, 100, 10)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT date_part('hour', q0."occurred_at") AS "hour", date_trunc('day', q0."occurred_at") AS "day", CASE WHEN ((q0."score" >= 50) AND (q0."score" <= 90)) THEN 'range' WHEN (q0."score" = 0) THEN NULL ELSE q0."score" END AS "normalized_score", stddev(q0."score") AS "score_stddev", variance(q0."score") AS "score_variance", mode(q0."score") AS "score_mode", weighted_avg(q0."score", q0."duration_ms") AS "weighted_score", skewness(q0."score") AS "score_skewness", kurtosis(q0."score") AS "score_kurtosis", sem(q0."score") AS "score_sem", geometric_mean(q0."score") AS "score_geometric_mean", corr(q0."score", q0."duration_ms") AS "score_correlation", covar_pop(q0."score", q0."duration_ms") AS "score_covar_pop", covar_samp(q0."score", q0."duration_ms") AS "score_covar_samp", regr_slope(q0."duration_ms", q0."score") AS "score_slope", regr_intercept(q0."duration_ms", q0."score") AS "score_intercept", entropy(q0."score") AS "score_entropy", mad(q0."score") AS "score_mad", histogram(q0."score") AS "score_histogram", histogram_exact(q0."score", ?) AS "exact_histogram", equi_width_bins(0, 100, 10, TRUE) AS "bins" FROM "events" AS q0]
  end

  test "builds aggregate analytical expressions" do
    query =
      from(event in "events",
        group_by: event.category,
        select: %{
          category: event.category,
          median_score: median(event.score),
          p95_score: quantile_cont(event.score, 0.95),
          p50_disc: quantile_disc(event.score, 0.5),
          scores: list(event.score),
          ordered_names: list(event.name, order_by: [desc_nulls_last: event.score]),
          names: string_agg(event.name, ","),
          ordered_names_text: string_agg(event.name, ",", order_by: [desc: event.score]),
          best_name: arg_max(event.name, event.score),
          top_names: arg_max(event.name, event.score, 2),
          worst_name: arg_min(event.name, event.score),
          bottom_names: arg_min(event.name, event.score, 2)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."category" AS "category", median(q0."score") AS "median_score", quantile_cont(q0."score", 0.95) AS "p95_score", quantile_disc(q0."score", 0.5) AS "p50_disc", list(q0."score") AS "scores", list(q0."name" ORDER BY q0."score" DESC NULLS LAST) AS "ordered_names", string_agg(q0."name", ',') AS "names", string_agg(q0."name", ',' ORDER BY q0."score" DESC) AS "ordered_names_text", arg_max(q0."name", q0."score") AS "best_name", arg_max(q0."name", q0."score", 2) AS "top_names", arg_min(q0."name", q0."score") AS "worst_name", arg_min(q0."name", q0."score", 2) AS "bottom_names" FROM "events" AS q0 GROUP BY q0."category"]
  end

  test "builds time buckets from Elixir durations" do
    interval = Duration.new!(minute: 15)

    query =
      from(event in "events",
        select: %{bucket: time_bucket(^interval, event.occurred_at)}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT time_bucket(?::INTERVAL, q0."occurred_at") AS "bucket" FROM "events" AS q0]
  end

  test "builds time buckets with origins and offsets" do
    interval = Duration.new!(hour: 1)
    origin = ~N[2024-01-01 00:00:00]
    offset = Duration.new!(minute: 15)

    query =
      from(event in "events",
        select: %{
          duration_interval: time_bucket(^interval, event.occurred_at, origin: ^origin),
          string_interval: time_bucket("1 hour", event.occurred_at, origin: ^origin),
          string_offset: time_bucket("1 hour", event.occurred_at, offset: ^offset)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT time_bucket(?::INTERVAL, q0."occurred_at", ?) AS "duration_interval", time_bucket('1 hour'::INTERVAL, q0."occurred_at", ?) AS "string_interval", time_bucket('1 hour'::INTERVAL, q0."occurred_at", ?) AS "string_offset" FROM "events" AS q0]
  end

  test "builds Ecto access JSON path expressions with casts" do
    query =
      from(event in "events",
        where:
          event.payload["user"]["name"] == "duck" and type(event.payload["score"], :integer) > 10,
        select: %{
          name: event.payload["user"]["name"],
          active: type(event.payload["active"], :boolean)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT json_extract_string(q0."payload", '$.user.name') AS "name", CAST(json_extract_string(q0."payload", '$.active') AS BOOLEAN) AS "active" FROM "events" AS q0 WHERE ((json_extract_string(q0."payload", '$.user.name') = 'duck') AND (CAST(json_extract_string(q0."payload", '$.score') AS INTEGER) > 10))]
  end

  test "builds JSON path-list expressions" do
    query =
      from(event in "events",
        where: json_extract_string(event.payload, [:user, :name]) == "duck",
        select: %{
          name: json_extract_string(event.payload, [:user, :name]),
          first_score: json_extract(event.payload, [:scores, 0]),
          dashed: json_extract_string(event.payload, ["display name"]),
          has_name: json_exists(event.payload, [:user, :name]),
          has_duck: json_contains(event.payload, ^{:json, %{name: "duck"}})
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             "SELECT json_extract_string(q0.\"payload\", '$.user.name') AS \"name\", " <>
               "json_extract(q0.\"payload\", '$.scores[0]') AS \"first_score\", " <>
               "json_extract_string(q0.\"payload\", '$[''display name'']') AS \"dashed\", " <>
               "json_exists(q0.\"payload\", '$.user.name') AS \"has_name\", " <>
               "json_contains(q0.\"payload\", ?) AS \"has_duck\" " <>
               "FROM \"events\" AS q0 WHERE (json_extract_string(q0.\"payload\", '$.user.name') = 'duck')"
  end

  test "builds JSON and time-series expressions" do
    query =
      from(event in "events",
        where: json_extract_string(event.payload, "$.kind") == "bird",
        select: %{
          name: json_extract_string(event.payload, "$.name"),
          raw_score: json_extract(event.payload, "$.score"),
          day: date_trunc("day", event.occurred_at),
          bucket: time_bucket("1 day", event.occurred_at)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT json_extract_string(q0."payload", '$.name') AS "name", json_extract(q0."payload", '$.score') AS "raw_score", date_trunc('day', q0."occurred_at") AS "day", time_bucket('1 day'::INTERVAL, q0."occurred_at") AS "bucket" FROM "events" AS q0 WHERE (json_extract_string(q0."payload", '$.kind') = 'bird')]
  end
end
