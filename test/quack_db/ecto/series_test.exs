defmodule QuackDB.Ecto.SeriesTest do
  use ExUnit.Case, async: true

  use QuackDB.Ecto

  alias Ecto.Adapters.QuackDB.Connection

  test "builds date series sources with a value field" do
    query =
      from(day in series(Date.range(~D[2024-01-01], ~D[2024-01-03])),
        order_by: day.value,
        select: %{day: day.value}
      )

    assert query |> Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."value" AS "day" FROM (SELECT CAST(generate_series AS DATE) AS value FROM generate_series(DATE '2024-01-01', DATE '2024-01-03', INTERVAL '0 months 1 days 0 microseconds')) AS q0 ORDER BY q0."value" ASC]
  end

  test "builds timestamp series sources with duration steps" do
    query =
      from(
        bucket in series(
          ~N[2024-01-01 00:00:00],
          ~N[2024-01-01 02:00:00],
          step: Duration.new!(minute: 30)
        ),
        select: %{bucket: bucket.value}
      )

    assert query |> Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."value" AS "bucket" FROM (SELECT generate_series AS value FROM generate_series(TIMESTAMP '2024-01-01 00:00:00', TIMESTAMP '2024-01-01 02:00:00', INTERVAL '0 months 0 days 1800000000 microseconds')) AS q0]
  end
end
