defmodule QuackDB.EctoTest do
  use ExUnit.Case, async: true

  test "serial_sequence_name returns migration sequence naming convention" do
    assert QuackDB.Ecto.serial_sequence_name("fragments", :id) == "fragments_id_seq"
    assert QuackDB.Ecto.serial_sequence_name(:fragments, "id") == "fragments_id_seq"

    assert QuackDB.Ecto.serial_sequence_name({"main", "fragments"}, :id) ==
             "main_fragments_id_seq"
  end
end
