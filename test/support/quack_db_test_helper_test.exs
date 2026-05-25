defmodule QuackDB.TestHelperTest do
  use ExUnit.Case, async: true

  import QuackDB.TestHelper

  test "unique_table builds prefixed names" do
    assert unique_table("events") =~ "events_"
  end

  test "csv_file! writes temporary files and registers cleanup" do
    path = csv_file!("id,name\n1,duck\n")

    assert File.read!(path) == "id,name\n1,duck\n"
  end

  test "source helpers write temporary files and return source SQL" do
    assert csv_source!("id,name\n1,duck\n") =~ "read_csv("
    assert json_source!(~s({"id":1}\n)) =~ "read_json("
  end

  test "insert_rows! builds quoted insert statements" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([2])

    connection =
      start_supervised!(
        {QuackDB,
         transport:
           QuackDB.TestTransports.transport(parent: parent, prepare: [chunk], names: ["Count"])}
      )

    insert_rows!(connection, "events", [[1, "duck"], [2, "goose"]], columns: [:id, :name])

    assert_received {:statement,
                     ~s[INSERT INTO "events" ("id", "name") VALUES (1, 'duck'), (2, 'goose')]}
  end
end
