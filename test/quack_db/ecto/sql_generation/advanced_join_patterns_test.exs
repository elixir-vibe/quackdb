defmodule QuackDB.Ecto.SQLGeneration.AdvancedJoinPatternsTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  test "renders semi join semantics through correlated exists" do
    query =
      from(event in "events",
        as: :event,
        where:
          exists(
            from(category in "categories",
              where: category.id == parent_as(:event).category_id,
              select: 1
            )
          ),
        select: event.id
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE EXISTS (SELECT 1 FROM "categories" AS s0_q0 WHERE (s0_q0."id" = q0."category_id"))]
  end

  test "renders anti join semantics through not exists" do
    query =
      from(event in "events",
        as: :event,
        where:
          not exists(
            from(category in "categories",
              where: category.id == parent_as(:event).category_id,
              select: 1
            )
          ),
        select: event.id
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "events" AS q0 WHERE (NOT EXISTS (SELECT 1 FROM "categories" AS s0_q0 WHERE (s0_q0."id" = q0."category_id")))]
  end

  test "renders ASOF-style latest match through a lateral top-one subquery" do
    latest_price =
      from(price in "prices",
        where:
          price.symbol == parent_as(:trade).symbol and
            price.ts <= parent_as(:trade).ts,
        order_by: [desc: price.ts],
        limit: 1,
        select: %{price: price.price}
      )

    query =
      from(trade in "trades",
        as: :trade,
        left_lateral_join: price in subquery(latest_price),
        on: true,
        select: %{trade_id: trade.id, price: price.price}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "trade_id", q1."price" AS "price" FROM "trades" AS q0 LEFT OUTER JOIN LATERAL (SELECT s1_q0."price" AS "price" FROM "prices" AS s1_q0 WHERE ((s1_q0."symbol" = q0."symbol") AND (s1_q0."ts" <= q0."ts")) ORDER BY s1_q0."ts" DESC LIMIT 1) AS q1 ON TRUE]
  end
end
