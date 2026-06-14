defmodule QuackDB.DMLTest do
  use ExUnit.Case, async: true

  alias QuackDB.DML
  alias QuackDB.Spatial

  test "builds parameterized DELETE statements" do
    assert {sql, params} =
             DML.delete_from(:events,
               where: [event_type: "session_entry", session_file: "session.json"]
             )

    assert IO.iodata_to_binary(sql) ==
             ~s|DELETE FROM "events" WHERE "event_type" = ? AND "session_file" = ?|

    assert params == ["session_entry", "session.json"]
  end

  test "builds DELETE statements with null and expression predicates" do
    assert {sql, params} =
             DML.delete_from("events",
               where: [deleted_at: nil, expires_at: {:expr, "current_timestamp"}]
             )

    assert IO.iodata_to_binary(sql) ==
             ~s|DELETE FROM "events" WHERE "deleted_at" IS NULL AND "expires_at" = current_timestamp|

    assert params == []
  end

  test "preserves list-valued DELETE parameters" do
    assert {sql, params} = DML.delete_from(:events, where: [ids: [1, 2, 3]])

    assert IO.iodata_to_binary(sql) == ~s|DELETE FROM "events" WHERE "ids" = ?|
    assert params == [[1, 2, 3]]
  end

  test "rejects DELETE without predicates" do
    assert_raise ArgumentError, ~r/expected delete where:/, fn ->
      DML.delete_from(:events, [])
    end

    assert_raise ArgumentError, ~r/at least one predicate/, fn ->
      DML.delete_from(:events, where: [])
    end
  end

  test "rejects non-keyword DELETE predicates" do
    assert_raise ArgumentError, ~r/keyword list/, fn ->
      DML.delete_from(:events, where: ["event_type"])
    end
  end

  test "builds INSERT statements from keyword rows" do
    assert DML.insert_into("events", id: 1, name: "duck")
           |> IO.iodata_to_binary() ==
             ~s|INSERT INTO "events" ("id", "name") VALUES (1, 'duck')|
  end

  test "builds multi-row INSERT statements" do
    assert DML.insert_into(:events, [[id: 1, active: true], [id: 2, active: false]])
           |> IO.iodata_to_binary() ==
             ~s|INSERT INTO "events" ("id", "active") VALUES (1, TRUE), (2, FALSE)|
  end

  test "builds INSERT statements from maps" do
    assert DML.insert_into("events", %{"id" => 1, "name" => "duck"})
           |> IO.iodata_to_binary() ==
             ~s|INSERT INTO "events" ("id", "name") VALUES (1, 'duck')|
  end

  test "rejects empty rows" do
    assert_raise ArgumentError, ~r/expected at least one insert row/, fn ->
      DML.insert_into("events", [])
    end
  end

  test "rejects empty columns" do
    assert_raise ArgumentError, ~r/expected at least one insert column/, fn ->
      DML.insert_into("events", [[]])
    end
  end

  test "rejects inconsistent row columns" do
    assert_raise ArgumentError, ~r/insert rows must have identical columns/, fn ->
      DML.insert_into("events", [[id: 1], [name: "duck"]])
    end
  end

  test "builds INSERT INTO SELECT statements" do
    assert DML.insert_into_select(
             {"main", "events"},
             [:id, :name],
             "staged_events",
             [:id, :name],
             on_conflict: {:nothing, [:id]},
             returning: [:id]
           )
           |> IO.iodata_to_binary() ==
             ~s|INSERT INTO "main"."events" ("id", "name") SELECT "id", "name" FROM "staged_events" ON CONFLICT ("id") DO NOTHING RETURNING "id"|
  end

  test "allows expression values" do
    assert DML.insert_into("places", id: 1, geom: {:expr, Spatial.point(1, 2)})
           |> IO.iodata_to_binary() ==
             ~s|INSERT INTO "places" ("id", "geom") VALUES (1, ST_Point(1, 2))|
  end
end
