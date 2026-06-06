defmodule QuackDB.Integration.AnalyticalSQLTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "raw SQL supports QUALIFY for window filtering" do
    start_repo!()

    assert {:ok, %{columns: ["category", "score", "rn"], rows: rows}} =
             QuackDB.IntegrationRepo.query("""
             SELECT category, score, row_number() OVER (PARTITION BY category ORDER BY score DESC) AS rn
             FROM (VALUES ('a', 10), ('a', 20), ('b', 5)) AS events(category, score)
             QUALIFY rn = 1
             ORDER BY category
             """)

    assert rows == [["a", 20, 1], ["b", 5, 1]]
  end

  test "raw SQL supports PIVOT" do
    start_repo!()

    source = """
    (
      SELECT 'duck' AS kind, 2 AS n
      UNION ALL
      SELECT 'goose' AS kind, 3 AS n
    )
    """

    assert {:ok, %{rows: rows} = result} =
             QuackDB.IntegrationRepo.query(
               QuackDB.SQL.pivot({:expr, source},
                 on: :kind,
                 using: [sum: :n]
               )
             )

    assert result.columns == ["duck", "goose"]
    assert rows == [[2, 3]]
  end

  test "raw SQL supports UNPIVOT" do
    start_repo!()

    statement = [
      QuackDB.SQL.unpivot({:expr, "(SELECT 2 AS duck, 3 AS goose)"},
        on: [:duck, :goose],
        name: :kind,
        value: :n
      ),
      " ORDER BY kind"
    ]

    assert {:ok, %{columns: ["kind", "n"], rows: rows}} =
             QuackDB.IntegrationRepo.query(statement)

    assert rows == [["duck", 2], ["goose", 3]]
  end

  test "raw SQL supports GROUPING SETS" do
    start_repo!()

    statement = [
      "SELECT category, kind, sum(n)::INTEGER AS total ",
      "FROM (VALUES ('bird', 'duck', 2), ('bird', 'goose', 3), ('fish', 'salmon', 5)) AS events(category, kind, n) ",
      "GROUP BY ",
      QuackDB.SQL.grouping_sets([[:category, :kind], [:category], []]),
      " ORDER BY category NULLS LAST, kind NULLS LAST"
    ]

    assert {:ok, %{columns: ["category", "kind", "total"], rows: rows}} =
             QuackDB.IntegrationRepo.query(statement)

    assert rows == [
             ["bird", "duck", 2],
             ["bird", "goose", 3],
             ["bird", nil, 5],
             ["fish", "salmon", 5],
             ["fish", nil, 5],
             [nil, nil, 10]
           ]
  end

  test "raw SQL supports sampling syntax" do
    start_repo!()

    assert {:ok, %{columns: ["n"], rows: rows}} =
             QuackDB.IntegrationRepo.query("""
             SELECT count(*)::INTEGER AS n
             FROM range(0, 100) USING SAMPLE reservoir(10 ROWS) REPEATABLE (42)
             """)

    assert rows == [[10]]
  end
end
