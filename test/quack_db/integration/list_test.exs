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

    assert %{rows: [[true, true, false, 1], [true, true, false, 2]]} =
             QuackDB.query!(conn, [
               "SELECT ",
               DuckList.contains("[1, 2, 3]", "2"),
               ", ",
               DuckList.has_any("[1, 2, 3]", "[3, 4]"),
               ", ",
               DuckList.has_all("[1, 2, 3]", "[2, 4]"),
               ", ",
               DuckList.unnest("[1, 2]"),
               " ORDER BY 4"
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
        select: %{id: row.id, all?: has_all(row.terms, ^[1, 2])}
      )

    assert [%{id: 1, all?: true}] = QuackDB.IntegrationRepo.all(query)
  end
end
