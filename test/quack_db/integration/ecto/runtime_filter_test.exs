defmodule QuackDB.Integration.Ecto.RuntimeFilterTest do
  use ExUnit.Case, async: false
  use QuackDB.Ecto
  import QuackDB.QuackServerCase
  alias QuackDB.IntegrationRepo, as: Repo
  alias QuackDB.Ecto.Decimal, as: DuckDecimal

  @moduletag :integration

  test "parameterized decimal casts preserve runtime precision, keys and result types" do
    start_repo!()
    Repo.query!("CREATE TABLE runtime_filters (id INTEGER, fields JSON)")

    for {id, value} <- [{1, "9.5"}, {2, "10.5"}, {3, "9.5001"}, {4, nil}] do
      Repo.query!("INSERT INTO runtime_filters VALUES (?, ?::JSON)", [
        id,
        Jason.encode!(%{estimate: value})
      ])
    end

    Repo.query!("INSERT INTO runtime_filters VALUES (5, '{}'::JSON)")
    key = "estimate"
    decimal = Ecto.ParameterizedType.init(DuckDecimal, precision: 18, scale: 4)
    estimate = dynamic([t], type(t.fields[^key], ^decimal))
    minimum = Decimal.new("9.5")
    predicate = dynamic([t], ^estimate > ^minimum)
    query = from(t in "runtime_filters", where: ^predicate, order_by: t.id, select: ^estimate)
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)
    assert sql =~ "DECIMAL(18, 4)"
    assert params == [minimum]
    assert Repo.all(query) == [Decimal.new("10.5000"), Decimal.new("9.5001")]

    assert Repo.all(from(t in "runtime_filters", where: t.id >= 4, select: ^estimate)) == [
             nil,
             nil
           ]

    # Scale is part of query identity, not a stale cached SQL cast.
    rounded = Ecto.ParameterizedType.init(DuckDecimal, precision: 18, scale: 3)
    rounded_expr = dynamic([t], type(t.fields[^key], ^rounded))
    rounded_predicate = dynamic([t], ^rounded_expr > ^minimum)
    assert Repo.all(from(t in "runtime_filters", where: ^rounded_predicate, select: t.id)) == [2]

    Repo.query!(~s|INSERT INTO runtime_filters VALUES (6, '{"estimate":"invalid"}')|)

    assert_raise QuackDB.Error, fn ->
      Repo.all(from(t in "runtime_filters", where: t.id == 6, select: ^estimate))
    end
  end

  test "contains options preserve literal matching and DuckDB lowercase semantics" do
    start_repo!()

    for {value, needle, expected} <- [
          {"AxB", "xb", true},
          {"a%b", "%", true},
          {"axb", "%", false},
          {"a_b", "_", true},
          {"axb", "_", false},
          {"a\\b", "\\", true},
          {"ÄBC", "äb", true},
          {"Straße", "STRASSE", false},
          {"abc", "", true},
          {nil, "x", nil},
          {"abc", nil, nil}
        ] do
      query =
        from(t in fragment("(SELECT 1 AS id)"),
          select: contains(^value, ^needle, case_sensitive: false)
        )

      assert Repo.one(query) == expected
    end

    query =
      from(t in fragment("(SELECT 1 AS id)"),
        select: contains("AxB", "xb", case_sensitive: true)
      )

    refute Repo.one(query)
  end
end
