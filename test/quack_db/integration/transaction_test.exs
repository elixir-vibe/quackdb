defmodule QuackDB.Integration.TransactionTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "transactions roll back through DBConnection" do
    connection = start_connection!()
    table = "qrollback_#{System.unique_integer([:positive])}"

    assert {:error, :rolled_back} =
             DBConnection.transaction(connection, fn tx ->
               QuackDB.query!(tx, QuackDB.DDL.create_table(table, [v: :integer], temporary: true))
               QuackDB.query!(tx, QuackDB.DML.insert_into(table, v: 1))
               DBConnection.rollback(tx, :rolled_back)
             end)

    assert {:error, %QuackDB.Error{message: message}} =
             QuackDB.query(connection, "SELECT count(*) FROM #{table}")

    assert message =~ "does not exist"
  end
end
