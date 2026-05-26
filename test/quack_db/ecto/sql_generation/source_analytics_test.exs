defmodule QuackDB.Ecto.SQLGeneration.SourceAnalyticsTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  test "generates aggregate queries over source helpers" do
    source =
      QuackDB.Source.parquet(["events/part-1.parquet", "events/part-2.parquet"],
        hive_partitioning: true
      )

    query =
      from(event in source,
        group_by: event.category,
        having: count(event.id) > 1,
        select: %{category: event.category, total_score: sum(event.score)}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~s|SELECT q0."category" AS "category", SUM(q0."score") AS "total_score" FROM read_parquet(['events/part-1.parquet', 'events/part-2.parquet'], hive_partitioning = TRUE) AS q0 GROUP BY q0."category" HAVING (COUNT(q0."id") > 1)|
  end

  test "generates source metadata queries" do
    source =
      QuackDB.Source.parquet("s3://bucket/events/**/*.parquet",
        filename: true,
        hive_partitioning: true,
        union_by_name: true
      )

    query =
      from(event in source,
        group_by: [event.year, event.month],
        select: %{
          year: event.year,
          month: event.month,
          files: count(event.filename),
          events: count()
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~s|SELECT q0."year" AS "year", q0."month" AS "month", COUNT(q0."filename") AS "files", COUNT(*) AS "events" FROM read_parquet('s3://bucket/events/**/*.parquet', filename = TRUE, hive_partitioning = TRUE, union_by_name = TRUE) AS q0 GROUP BY q0."year", q0."month"|
  end

  test "generates window queries over source helpers" do
    source = QuackDB.Source.csv("events.csv", header: true)

    query =
      from(event in source,
        windows: [by_category: [partition_by: event.category, order_by: [desc: event.score]]],
        select: %{
          category: event.category,
          name: event.name,
          rank: over(rank(), :by_category)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."category" AS "category", q0."name" AS "name", RANK() OVER "by_category" AS "rank" FROM read_csv('events.csv', header = TRUE) AS q0 WINDOW "by_category" AS (PARTITION BY q0."category" ORDER BY q0."score" DESC)]
  end
end
