defmodule QuackDB.Integration.MapStructTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.Ecto.Map
  import QuackDB.Ecto.Struct
  import QuackDB.QuackServerCase

  alias QuackDB.Map, as: DuckMap
  alias QuackDB.Struct, as: DuckStruct

  @moduletag :integration

  test "direct map and struct helpers run against DuckDB" do
    conn = start_connection!()
    map = "map(['env', 'region'], ['prod', 'eu'])"
    struct = "{'name': 'duck', 'score': 10}"

    assert %{rows: [[2, ["env", "region"], true, "prod", "duck", 10]]} =
             QuackDB.query!(conn, [
               "SELECT ",
               DuckMap.cardinality(map),
               ", ",
               DuckMap.keys(map),
               ", ",
               DuckMap.contains(map, "'env'"),
               ", ",
               DuckMap.extract_value(map, "'env'"),
               ", ",
               DuckStruct.extract(struct, "'name'"),
               ", ",
               DuckStruct.extract(struct, "'score'")
             ])
  end

  test "Ecto map and struct helpers query nested values" do
    start_repo!()

    map_query =
      from(row in fragment("(SELECT map(['env', 'region'], ['prod', 'eu']) AS labels)"),
        where: contains_map(row.labels, ^"env"),
        select: %{
          size: map_cardinality(row.labels),
          keys: map_keys(row.labels),
          env: map_extract_value(row.labels, ^"env")
        }
      )

    struct_query =
      from(
        row in fragment(
          "(SELECT {'name': 'duck', 'score': 10} AS metadata, row('duck', 10) AS tuple)"
        ),
        where: contains_struct(row.tuple, ^"duck"),
        select: %{
          name: struct_extract(row.metadata, ^"name"),
          score: struct_extract(row.metadata, ^"score")
        }
      )

    assert [%{size: 2, keys: ["env", "region"], env: "prod"}] =
             QuackDB.IntegrationRepo.all(map_query)

    assert [%{name: "duck", score: 10}] = QuackDB.IntegrationRepo.all(struct_query)
  end
end
