defmodule QuackDB.Ecto.SQLGeneration.SourceCombinationsTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias QuackDB.Source

  test "generates union_all over source queries" do
    first =
      from(event in Source.parquet("2024.parquet"),
        select: %{id: event.id, name: event.name}
      )

    second =
      from(event in Source.parquet("2025.parquet"),
        select: %{id: event.id, name: event.name}
      )

    query = union_all(first, ^second)

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~s|SELECT q0."id" AS "id", q0."name" AS "name" FROM read_parquet('2024.parquet') AS q0 UNION ALL SELECT q0."id" AS "id", q0."name" AS "name" FROM read_parquet('2025.parquet') AS q0|
  end
end
