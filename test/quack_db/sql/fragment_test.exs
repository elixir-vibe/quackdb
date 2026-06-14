defmodule QuackDB.SQL.FragmentTest do
  use ExUnit.Case, async: true

  alias QuackDB.SQL.Fragment

  test "quotes table names" do
    assert Fragment.table("events") |> IO.iodata_to_binary() == ~s|"events"|
    assert Fragment.table({"main", "events"}) |> IO.iodata_to_binary() == ~s|"main"."events"|
    assert Fragment.table({nil, "events"}) |> IO.iodata_to_binary() == ~s|"events"|
  end

  test "builds column fragments" do
    assert Fragment.column_list([:id, "event name"]) |> IO.iodata_to_binary() ==
             ~s|"id", "event name"|

    assert Fragment.qualified_column(:source, :id) |> IO.iodata_to_binary() ==
             ~s|"source"."id"|

    assert Fragment.qualified_column_list([:id, :name], :source) |> IO.iodata_to_binary() ==
             ~s|"source"."id", "source"."name"|
  end

  test "builds insert/select tail fragments" do
    assert Fragment.insert_columns([:id, :name]) |> IO.iodata_to_binary() ==
             ~s| ("id", "name")|

    assert Fragment.select_columns([]) |> IO.iodata_to_binary() == "*"
    assert Fragment.returning([:id]) |> IO.iodata_to_binary() == ~s| RETURNING "id"|
    assert Fragment.on_conflict(:nothing) |> IO.iodata_to_binary() == " ON CONFLICT DO NOTHING"

    assert Fragment.on_conflict({:nothing, [:id]}) |> IO.iodata_to_binary() ==
             ~s| ON CONFLICT ("id") DO NOTHING|
  end

  test "builds qualified predicates" do
    assert Fragment.qualified_equality(:target, :id, :source, :event_id)
           |> IO.iodata_to_binary() ==
             ~s|"target"."id" = "source"."event_id"|

    assert Fragment.qualified_not_distinct(:target, :id, :source, :event_id)
           |> IO.iodata_to_binary() ==
             ~s|"target"."id" IS NOT DISTINCT FROM "source"."event_id"|
  end

  test "builds window fragments" do
    assert Fragment.row_number_over(
             partition_by: [:content_hash],
             order_by: [:file_id, {:line, :asc}, {:end_line, :asc, nulls: :last}],
             as: :stage_row
           )
           |> IO.iodata_to_binary() ==
             ~s|row_number() OVER (PARTITION BY "content_hash" ORDER BY "file_id", "line" ASC, "end_line" ASC NULLS LAST) AS "stage_row"|
  end

  test "builds select and union fragments" do
    left =
      Fragment.select([:term_id, :fragment_id] |> Enum.map(&Fragment.column/1),
        from: "fragment_terms",
        distinct: true
      )

    right =
      Fragment.select(
        [
          Fragment.as(["unnest(", Fragment.column(:terms), ")"], :term_id),
          Fragment.as(Fragment.column(:id), :fragment_id)
        ],
        from: "fragments",
        distinct: true
      )

    assert Fragment.union([left, right], order_by: [:term_id, :fragment_id])
           |> IO.iodata_to_binary() ==
             ~s|SELECT DISTINCT "term_id", "fragment_id" FROM "fragment_terms" UNION SELECT DISTINCT unnest("terms") AS "term_id", "id" AS "fragment_id" FROM "fragments" ORDER BY "term_id", "fragment_id"|
  end

  test "builds where and join fragments" do
    assert Fragment.where(~s|"id" IS NOT NULL|) |> IO.iodata_to_binary() ==
             ~s| WHERE "id" IS NOT NULL|

    assert Fragment.join(:left, "files", as: :file, on: ~s|"file"."id" = "s"."file_id"|)
           |> IO.iodata_to_binary() ==
             ~s| LEFT JOIN "files" AS "file" ON "file"."id" = "s"."file_id"|
  end
end
