defmodule QuackDB.Ecto.AnalyticsTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import QuackDB.Ecto.Analytics

  test "builds aggregate analytical expressions" do
    query =
      from(event in "events",
        group_by: event.category,
        select: %{
          category: event.category,
          median_score: median(event.score),
          p95_score: quantile_cont(event.score, 0.95),
          p50_disc: quantile_disc(event.score, 0.5),
          scores: duckdb_list(event.score),
          names: string_agg(event.name, ","),
          best_name: arg_max(event.name, event.score),
          worst_name: arg_min(event.name, event.score)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."category" AS "category", median(q0."score") AS "median_score", quantile_cont(q0."score", 0.95) AS "p95_score", quantile_disc(q0."score", 0.5) AS "p50_disc", list(q0."score") AS "scores", string_agg(q0."name", ',') AS "names", arg_max(q0."name", q0."score") AS "best_name", arg_min(q0."name", q0."score") AS "worst_name" FROM "events" AS q0 GROUP BY q0."category"]
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

  test "builds Ecto access JSON path expressions" do
    query =
      from(event in "events",
        where: event.payload["user"]["name"] == "duck",
        select: %{name: event.payload["user"]["name"]}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT json_extract_string(q0."payload", '$.user.name') AS "name" FROM "events" AS q0 WHERE (json_extract_string(q0."payload", '$.user.name') = 'duck')]
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
