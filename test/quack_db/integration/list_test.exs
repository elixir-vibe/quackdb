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

  test "Ecto list lambda helpers query LIST columns" do
    start_repo!()
    table = TestHelper.unique_table("quackdb_list_lambda_helpers")

    TestHelper.create_table!(QuackDB.IntegrationRepo, table,
      id: :integer,
      scores: {:list, :integer}
    )

    QuackDB.IntegrationRepo.query!("INSERT INTO #{table} VALUES (1, [1, 2, 3]), (2, [3, 4, 5])")

    min_score = 1

    query =
      from(row in table,
        order_by: row.id,
        select: %{
          id: row.id,
          filtered: list_filter(row.scores, fn x -> x > ^min_score and not is_nil(x) end),
          above_index: list_filter(row.scores, fn x, i -> not is_nil(x) and x > i end),
          doubled: list_transform(row.scores, fn x -> x * 2 end),
          shifted: list_transform(row.scores, fn x, i -> x + i end),
          total: list_reduce(row.scores, fn acc, x -> acc + x end),
          initial_total: list_reduce(row.scores, fn acc, x -> acc + x end, 10)
        }
      )

    assert [first, second] = QuackDB.IntegrationRepo.all(query)

    assert %{
             id: 1,
             filtered: [2, 3],
             above_index: [],
             doubled: [2, 4, 6],
             shifted: [2, 4, 6],
             total: 6,
             initial_total: 16
           } = first

    assert %{
             id: 2,
             filtered: [3, 4, 5],
             above_index: [3, 4, 5],
             doubled: [6, 8, 10],
             shifted: [4, 6, 8],
             total: 12,
             initial_total: 22
           } = second
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
