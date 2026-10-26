defmodule QuackDB.Ecto.SQLGeneration.PrefixTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Adapters.QuackDB.Connection

  defmodule Ledger do
    use Ecto.Schema

    @schema_prefix "finance"
    @primary_key false
    schema "ledger" do
      field(:amount, :integer)
    end
  end

  test "source prefixes qualify reads" do
    query = from(entry in "ledger", prefix: "finance", select: entry.amount)

    assert sql(query) == ~S[SELECT q0."amount" FROM "finance"."ledger" AS q0]
  end

  test "schema prefixes qualify reads" do
    query = from(entry in Ledger, select: entry.amount)

    assert sql(query) == ~S[SELECT q0."amount" FROM "finance"."ledger" AS q0]
  end

  test "query prefixes apply to sources without their own" do
    query =
      from(entry in "ledger",
        join: account in "accounts",
        prefix: "audit",
        on: account.id == entry.account_id,
        select: entry.amount
      )

    query = %{query | prefix: "finance"}

    assert sql(query) ==
             ~S[SELECT q0."amount" FROM "finance"."ledger" AS q0 INNER JOIN "audit"."accounts" AS q1 ON (q1."id" = q0."account_id")]
  end

  test "dotted prefixes name nested schemas" do
    query = from(entry in "ledger", prefix: "finance.reports", select: entry.amount)

    assert sql(query) == ~S[SELECT q0."amount" FROM "finance"."reports"."ledger" AS q0]
  end

  test "query prefixes skip CTE names, as Ecto's planner does" do
    large = from(entry in "ledger", where: entry.amount > 10, select: %{id: entry.id})
    others = from(big in "large", select: big.id)

    query =
      "ledger"
      |> with_cte("large", as: ^large)
      |> join(:inner, [entry], big in "large", on: big.id == entry.id)
      |> select([entry], entry.id)
      |> union(^others)

    assert planned_sql(%{query | prefix: "finance"}) ==
             ~S[WITH "large" AS (SELECT q0."id" AS "id" FROM "finance"."ledger" AS q0 WHERE (q0."amount" > 10)) ] <>
               ~S[SELECT q0."id" FROM "finance"."ledger" AS q0 INNER JOIN "large" AS q1 ON (q1."id" = q0."id") ] <>
               ~S[UNION SELECT q0."id" FROM "large" AS q0]
  end

  test "mutations honor prefixes" do
    update = from(entry in "ledger", prefix: "finance", update: [set: [amount: 0]])
    delete = %{from(entry in "ledger", where: entry.amount < 0) | prefix: "finance"}

    assert update |> Connection.update_all() |> IO.iodata_to_binary() ==
             ~S[UPDATE "finance"."ledger" AS q0 SET "amount" = ?]

    assert delete |> Connection.delete_all() |> IO.iodata_to_binary() ==
             ~S[DELETE FROM "finance"."ledger" AS q0 WHERE (q0."amount" < ?)]
  end

  defp sql(query), do: query |> Connection.all() |> IO.iodata_to_binary()

  # The planner copies the query prefix into CTE bodies and UNION operands.
  defp planned_sql(query) do
    {planned, _params, _cache_key} = Ecto.Query.Planner.plan(query, :all, Ecto.Adapters.QuackDB)
    {normalized, _decoder} = Ecto.Query.Planner.normalize(planned, :all, Ecto.Adapters.QuackDB, 0)
    sql(normalized)
  end
end
