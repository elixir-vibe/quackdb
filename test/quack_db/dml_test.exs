defmodule QuackDB.DMLTest do
  use ExUnit.Case, async: true

  alias QuackDB.DML
  alias QuackDB.Spatial

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

  test "allows expression values" do
    assert DML.insert_into("places", id: 1, geom: {:expr, Spatial.point(1, 2)})
           |> IO.iodata_to_binary() ==
             ~s|INSERT INTO "places" ("id", "geom") VALUES (1, ST_Point(1, 2))|
  end
end
