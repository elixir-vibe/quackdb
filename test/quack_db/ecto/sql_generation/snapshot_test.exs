defmodule QuackDB.Ecto.SQLGeneration.SnapshotTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import QuackDB.Ecto.Snapshot

  alias Ecto.Adapters.QuackDB.Connection

  defmodule Customer do
    use Ecto.Schema

    schema "customers" do
      field(:name, :string)
    end
  end

  defmodule Tag do
    use Ecto.Schema

    schema "tags" do
      field(:name, :string)
    end
  end

  defmodule Order do
    use Ecto.Schema

    schema "orders" do
      field(:status, :string)
      belongs_to(:customer, Customer)
      many_to_many(:tags, Tag, join_through: "order_tags")
    end
  end

  @version "AT (VERSION => 42)"
  @timestamp "AT (TIMESTAMP => TIMESTAMPTZ '2026-10-20T14:03:11Z')"

  test "a version or a DateTime reads every table at that snapshot" do
    query = from(order in Order, select: order.id)

    assert planned_sql(put_snapshot(query, version: 42)) ==
             ~s[SELECT q0."id" FROM "orders" AS q0 #{@version}]

    assert planned_sql(put_snapshot(query, ~U[2026-10-20 14:03:11Z])) ==
             ~s[SELECT q0."id" FROM "orders" AS q0 #{@timestamp}]

    assert planned_sql(put_snapshot(query, timestamp: ~U[2026-10-20 14:03:11Z])) ==
             ~s[SELECT q0."id" FROM "orders" AS q0 #{@timestamp}]
  end

  test "assoc joins and their join tables read the same snapshot" do
    query =
      from(order in Order,
        join: customer in assoc(order, :customer),
        join: tag in assoc(order, :tags),
        select: {order.id, customer.name, tag.name}
      )

    sql = planned_sql(put_snapshot(query, version: 42))

    assert sql =~ ~s["orders" AS q0 #{@version}]
    assert sql =~ ~s["customers" AS q1 #{@version}]
    assert sql =~ ~s["order_tags" AS q2 #{@version}]
    assert sql =~ ~s["tags" AS q3 #{@version}]
  end

  test "subqueries and CTE bodies read the snapshot, CTE names do not" do
    paid = from(order in "orders", where: order.status == "paid", select: %{id: order.id})

    query =
      from(order in "orders",
        join: recent in "recent",
        on: recent.id == order.id,
        where: order.id in subquery(from(customer in "customers", select: customer.id)),
        select: order.id
      )
      |> with_cte("recent", as: ^paid)
      |> put_snapshot(version: 42)

    sql = planned_sql(query)

    assert sql =~ ~s[WITH "recent" AS (SELECT q0."id" AS "id" FROM "orders" AS q0 #{@version}]
    assert sql =~ ~s["orders" AS q0 #{@version} INNER JOIN "recent" AS q1 ON]
    assert sql =~ ~s["customers" AS q0 #{@version}]
  end

  test "put_snapshot/3 reads one binding, and overrides the query's snapshot" do
    query =
      from(order in Order,
        as: :order,
        join: region in "regions",
        as: :region,
        on: region.id == order.id,
        select: order.id
      )

    assert planned_sql(put_snapshot(query, :order, version: 7)) ==
             ~s[SELECT q0."id" FROM "orders" AS q0 AT (VERSION => 7) ] <>
               ~s[INNER JOIN "regions" AS q1 ON (q1."id" = q0."id")]

    both = query |> put_snapshot(version: 42) |> put_snapshot(:region, version: 7)

    assert planned_sql(both) ==
             ~s[SELECT q0."id" FROM "orders" AS q0 #{@version} ] <>
               ~s[INNER JOIN "regions" AS q1 AT (VERSION => 7) ON (q1."id" = q0."id")]
  end

  test "a later snapshot replaces an earlier one" do
    query = Order |> put_snapshot(version: 1) |> put_snapshot(version: 42) |> select([o], o.id)
    assert planned_sql(query) == ~s[SELECT q0."id" FROM "orders" AS q0 #{@version}]

    query = from(o in Order, as: :order, select: o.id)
    query = query |> put_snapshot(:order, version: 1) |> put_snapshot(:order, version: 42)
    assert planned_sql(query) == ~s[SELECT q0."id" FROM "orders" AS q0 #{@version}]
  end

  test "a nil snapshot leaves the query unchanged" do
    assert put_snapshot(Order, nil) == Ecto.Queryable.to_query(Order)
    assert put_snapshot(Order, :order, nil) == Ecto.Queryable.to_query(Order)
  end

  test "hints render after the alias" do
    query = from(order in "orders", hints: ["TABLESAMPLE 10%"], select: order.id)
    assert planned_sql(query) == ~s[SELECT q0."id" FROM "orders" AS q0 TABLESAMPLE 10%]
  end

  test "invalid snapshots, bindings, and assoc bindings raise" do
    assert_raise ArgumentError, ~r/expected a snapshot/, fn ->
      put_snapshot(Order, version: -1)
    end

    assert_raise ArgumentError, ~r/expected a snapshot/, fn ->
      put_snapshot(Order, ~N[2026-01-01 00:00:00])
    end

    assert_raise ArgumentError, ~r/unknown named binding :nope/, fn ->
      put_snapshot(Order, :nope, version: 1)
    end

    query = from(order in Order, join: customer in assoc(order, :customer), as: :customer)

    assert_raise ArgumentError, ~r/assoc join to :customer/, fn ->
      put_snapshot(query, :customer, version: 1)
    end
  end

  test "the :snapshot repo option applies to reads and raises for mutations" do
    assert {query, [snapshot: [version: 42]]} =
             prepare_query(:all, Ecto.Queryable.to_query(Order), snapshot: [version: 42])

    assert planned_sql(select(query, [o], o.id)) ==
             ~s[SELECT q0."id" FROM "orders" AS q0 #{@version}]

    query = Ecto.Queryable.to_query(Order)
    assert prepare_query(:update_all, query, []) == {query, []}

    assert_raise ArgumentError, ~r/snapshots are read-only/, fn ->
      prepare_query(:delete_all, query, snapshot: [version: 42])
    end
  end

  test "mutations reject snapshots" do
    query = from(order in "orders", update: [set: [status: "paid"]]) |> put_snapshot(version: 42)

    assert_raise QuackDB.Error, ~r/snapshots, are unsupported for update_all/, fn ->
      Connection.update_all(query)
    end
  end

  defp planned_sql(query) do
    {planned, _params, _cache_key} = Ecto.Query.Planner.plan(query, :all, Ecto.Adapters.QuackDB)
    {normalized, _decoder} = Ecto.Query.Planner.normalize(planned, :all, Ecto.Adapters.QuackDB, 0)
    normalized |> Connection.all() |> IO.iodata_to_binary()
  end
end
