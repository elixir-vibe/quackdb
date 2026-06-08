defmodule QuackDB.EctoTest do
  use ExUnit.Case, async: true

  test "column_sequence_name returns migration sequence naming convention" do
    assert QuackDB.Ecto.column_sequence_name("fragments", :id) == "fragments_id_seq"
    assert QuackDB.Ecto.column_sequence_name(:fragments, "id") == "fragments_id_seq"

    assert QuackDB.Ecto.column_sequence_name({"main", "fragments"}, :id) ==
             "main_fragments_id_seq"
  end

  test "column_sequence_name uses Ecto schema source metadata" do
    assert QuackDB.Ecto.column_sequence_name(QuackDB.TestSchemas.RenamedEvent, :name) ==
             "renamed_events_event_name_seq"

    assert QuackDB.Ecto.column_sequence_name(
             {"tenant_events", QuackDB.TestSchemas.RenamedEvent},
             :name
           ) ==
             "tenant_events_event_name_seq"
  end
end
