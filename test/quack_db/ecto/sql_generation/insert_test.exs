defmodule QuackDB.Ecto.SQLGeneration.InsertTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Adapters.QuackDB.Connection

  test "generates insert_all SQL with placeholders" do
    sql =
      Connection.insert(
        nil,
        "events",
        [:id, :name],
        [[:id, :name], [:id, :name]],
        {:raise, [], []},
        [],
        []
      )
      |> IO.iodata_to_binary()

    assert sql == ~s|INSERT INTO "events" ("id", "name") VALUES (?, ?), (?, ?)|
  end

  test "generates insert_all SQL placeholders for nil values" do
    sql =
      Connection.insert(
        nil,
        "events",
        [:id, :name],
        [[nil, :name]],
        {:raise, [], []},
        [],
        []
      )
      |> IO.iodata_to_binary()

    assert sql == ~s|INSERT INTO "events" ("id", "name") VALUES (?, ?)|
  end

  test "generates insert from query with not exists and returning" do
    staging_query =
      from(row in "staging_fragments",
        as: :row,
        where:
          not exists(
            from(target in "fragments",
              where: target.content_hash == parent_as(:row).content_hash,
              select: 1
            )
          ),
        select: %{
          content_hash: row.content_hash,
          ast: row.ast,
          kind: row.kind
        }
      )

    sql =
      Connection.insert(
        nil,
        "fragments",
        [:content_hash, :ast, :kind],
        staging_query,
        {:raise, [], []},
        [:id, :content_hash],
        []
      )
      |> IO.iodata_to_binary()

    assert sql ==
             ~s|INSERT INTO "fragments" ("content_hash", "ast", "kind") (SELECT q0."content_hash" AS "content_hash", q0."ast" AS "ast", q0."kind" AS "kind" FROM "staging_fragments" AS q0 WHERE (NOT EXISTS (SELECT 1 FROM "fragments" AS s0_q0 WHERE (s0_q0."content_hash" = q0."content_hash")))) RETURNING "id", "content_hash"|
  end

  test "generates insert SQL with returning" do
    sql =
      Connection.insert(
        nil,
        "events",
        [:name],
        [[:name]],
        {:raise, [], []},
        [:id],
        []
      )
      |> IO.iodata_to_binary()

    assert sql == ~s|INSERT INTO "events" ("name") VALUES (?) RETURNING "id"|
  end

  test "generates on conflict do nothing" do
    sql =
      Connection.insert(
        nil,
        "events",
        [:id],
        [[:id]],
        {:nothing, [], [:id]},
        [],
        []
      )
      |> IO.iodata_to_binary()

    assert sql == ~s|INSERT INTO "events" ("id") VALUES (?) ON CONFLICT ("id") DO NOTHING|
  end

  test "generates on conflict update with explicit replacement values" do
    sql =
      Connection.insert(
        nil,
        "events",
        [:id, :name],
        [[:id, :name]],
        {[name: "mallard"], [], [:id]},
        [],
        []
      )
      |> IO.iodata_to_binary()

    assert sql ==
             ~s|INSERT INTO "events" ("id", "name") VALUES (?, ?) ON CONFLICT ("id") DO UPDATE SET "name" = ?|
  end

  test "generates on conflict update with increment expressions" do
    query = from(event in "events", update: [inc: [score: 1]])

    sql =
      Connection.insert(
        nil,
        "events",
        [:id, :score],
        [[:id, :score]],
        {query, [], [:id]},
        [],
        []
      )
      |> IO.iodata_to_binary()

    assert sql ==
             ~s|INSERT INTO "events" ("id", "score") VALUES (?, ?) ON CONFLICT ("id") DO UPDATE SET "score" = "score" + ?|
  end

  test "generates on conflict update with unsafe conflict targets" do
    sql =
      Connection.insert(
        nil,
        "events",
        [:id, :name],
        [[:id, :name]],
        {[:name], [], {:unsafe_fragment, "ON CONSTRAINT events_id_key"}},
        [],
        []
      )
      |> IO.iodata_to_binary()

    assert sql ==
             ~s|INSERT INTO "events" ("id", "name") VALUES (?, ?) ON CONFLICT ON CONSTRAINT events_id_key DO UPDATE SET "name" = EXCLUDED."name"|
  end

  test "generates on conflict update" do
    sql =
      Connection.insert(nil, "events", [:id, :name], [[:id, :name]], {[:name], [], [:id]}, [], [])
      |> IO.iodata_to_binary()

    assert sql ==
             ~s|INSERT INTO "events" ("id", "name") VALUES (?, ?) ON CONFLICT ("id") DO UPDATE SET "name" = EXCLUDED."name"|
  end
end
