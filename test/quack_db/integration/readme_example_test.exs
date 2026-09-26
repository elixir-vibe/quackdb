defmodule QuackDB.Integration.ReadmeExampleTest do
  @moduledoc "The README's first example, run against a real DuckDB and a real Parquet file."
  use ExUnit.Case, async: false

  use QuackDB.Ecto

  import QuackDB.QuackServerCase

  alias QuackDB.IntegrationRepo, as: Repo
  alias QuackDB.Source

  @moduletag :integration

  # Daily API latency for a month, read straight from the lakehouse,
  # with every day present even when nothing happened.
  defp daily_latency(events, days) do
    from(day in series(days),
      left_join: event in ^events,
      on: event.occurred_on == day.value and regexp_matches(event.path, ~r"^/api/"),
      group_by: day.value,
      order_by: day.value,
      select: %{
        day: day.value,
        requests: count(event.id),
        errors: filter(count(event.id), event.status >= 500),
        p95_ms: quantile_cont(event.duration_ms, 0.95),
        slowest: arg_max(event.path, event.duration_ms)
      }
    )
  end

  test "the README example: series, parquet source, regex, filtered aggregates, dataframe" do
    start_repo!()

    path =
      Path.join(System.tmp_dir!(), "quackdb_readme_#{System.unique_integer([:positive])}.parquet")

    on_exit(fn -> File.rm(path) end)

    Repo.query!(
      """
      COPY (
        SELECT * FROM (VALUES
          (1, DATE '2024-01-01', '/api/users', 200, 120),
          (2, DATE '2024-01-01', '/api/users', 500, 900),
          (3, DATE '2024-01-01', '/assets/app.js', 200, 5),
          (4, DATE '2024-01-03', '/api/orders', 200, 300)
        ) AS t(id, occurred_on, path, status, duration_ms)
      ) TO ? (FORMAT parquet)
      """,
      [path]
    )

    query = daily_latency(Source.parquet(path), Date.range(~D[2024-01-01], ~D[2024-01-03]))

    assert [
             %{day: ~D[2024-01-01], requests: 2, errors: 1, p95_ms: p95, slowest: "/api/users"},
             %{day: ~D[2024-01-02], requests: 0, errors: 0, p95_ms: nil, slowest: nil},
             %{day: ~D[2024-01-03], requests: 1, errors: 0, p95_ms: 300.0, slowest: "/api/orders"}
           ] = Repo.all(query)

    assert_in_delta p95, 861.0, 1.0

    frame = QuackDB.Explorer.dataframe!(Repo, query)
    # A map select orders its columns by key.
    assert Explorer.DataFrame.names(frame) == ["day", "errors", "p95_ms", "requests", "slowest"]
    assert Explorer.DataFrame.n_rows(frame) == 3
    assert Explorer.Series.to_list(frame["requests"]) == [2, 0, 1]
  end
end
