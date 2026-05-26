defmodule QuackDB.Integration.Ecto.SeriesTest do
  use ExUnit.Case, async: false

  use QuackDB.Ecto

  import QuackDB.QuackServerCase
  import QuackDB.TestHelper

  @moduletag :integration

  test "date series joins against event facts" do
    start_repo!()
    table = unique_table("quackdb_ecto_series_events")

    create_table!(QuackDB.IntegrationRepo, table, occurred_on: :date, duration_ms: :integer)

    insert_rows!(QuackDB.IntegrationRepo, table, [
      [~D[2024-01-01], 10],
      [~D[2024-01-01], 20],
      [~D[2024-01-03], 30]
    ])

    query =
      from(day in series(Date.range(~D[2024-01-01], ~D[2024-01-03])),
        left_join: event in ^table,
        on: event.occurred_on == day.value,
        group_by: day.value,
        order_by: day.value,
        select: %{day: day.value, events: count(event.occurred_on)}
      )

    assert [
             %{day: ~D[2024-01-01], events: 2},
             %{day: ~D[2024-01-02], events: 0},
             %{day: ~D[2024-01-03], events: 1}
           ] = QuackDB.IntegrationRepo.all(query)
  end

  test "timestamp series accepts duration steps" do
    start_repo!()

    query =
      from(
        bucket in series(
          ~N[2024-01-01 00:00:00],
          ~N[2024-01-01 01:00:00],
          step: Duration.new!(minute: 30)
        ),
        order_by: bucket.value,
        select: bucket.value
      )

    assert [
             ~N[2024-01-01 00:00:00],
             ~N[2024-01-01 00:30:00],
             ~N[2024-01-01 01:00:00]
           ] = QuackDB.IntegrationRepo.all(query)
  end
end
