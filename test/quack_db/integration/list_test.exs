defmodule QuackDB.Integration.ListTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.Ecto.List
  import QuackDB.QuackServerCase

  alias QuackDB.List, as: DuckList
  alias QuackDB.TestHelper

  @moduletag :integration

  test "direct list helpers run against DuckDB" do
    conn = start_connection!()

    assert %{
             rows: [
               [3, 2, [1, 2], [1, 2, 3], 2, 2, true, true, false, 1],
               [3, 2, [1, 2], [1, 2, 3], 2, 2, true, true, false, 2]
             ]
           } =
             QuackDB.query!(conn, [
               "SELECT ",
               DuckList.length("[1, 2, 3]"),
               ", ",
               DuckList.extract("[1, 2, 3]", "2"),
               ", ",
               DuckList.slice("[1, 2, 3]", "1", "2"),
               ", ",
               DuckList.sort("[3, 1, 2]"),
               ", ",
               DuckList.unique("[1, 1, 2, NULL]"),
               ", ",
               DuckList.position("[1, 2, 3]", "2"),
               ", ",
               DuckList.contains("[1, 2, 3]", "2"),
               ", ",
               DuckList.has_any("[1, 2, 3]", "[3, 4]"),
               ", ",
               DuckList.has_all("[1, 2, 3]", "[2, 4]"),
               ", ",
               DuckList.unnest("[1, 2]"),
               " ORDER BY 10"
             ])
  end

  test "Ecto list helpers query LIST columns" do
    start_repo!()
    table = TestHelper.unique_table("quackdb_list_helpers")

    TestHelper.create_table!(QuackDB.IntegrationRepo, table,
      id: :integer,
      terms: {:list, :integer}
    )

    QuackDB.IntegrationRepo.query!(
      "INSERT INTO #{table} VALUES (1, [1, 2, 3]), (2, [2, 4]), (3, [])"
    )

    query =
      from(row in table,
        where: contains_list(row.terms, ^2) and has_any(row.terms, ^[3, 9]),
        order_by: row.id,
        select: %{
          id: row.id,
          all?: has_all(row.terms, ^[1, 2]),
          count: list_length(row.terms),
          second: extract(row.terms, 2),
          sorted: sort(row.terms),
          overlap: intersect_list(row.terms, ^[2, 9])
        }
      )

    assert [result] = QuackDB.IntegrationRepo.all(query)
    assert %{id: 1, all?: true, count: 3, second: 2, sorted: [1, 2, 3], overlap: [2]} = result
  end
end
