defmodule QuackDB.Integration.TransactionTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "classifies concurrent update conflicts as retriable" do
    first = start_connection!()
    second = start_connection!()
    table = "qconflict_#{System.unique_integer([:positive])}"

    QuackDB.query!(first, "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, value INTEGER)")
    QuackDB.query!(first, "INSERT INTO #{table} VALUES (1, 0)")

    parent = self()

    writer =
      Task.async(fn ->
        DBConnection.transaction(first, fn tx ->
          QuackDB.query!(tx, "UPDATE #{table} SET value = value + 1 WHERE id = 1")
          send(parent, :first_writer_ready)

          receive do
            :release_first_writer -> :ok
          end
        end)
      end)

    assert_receive :first_writer_ready

    assert {:error, :rollback} =
             DBConnection.transaction(second, fn tx ->
               assert {:error,
                       %QuackDB.Error{
                         code: :transaction_conflict,
                         retriable?: true,
                         message: "Conflict on update!"
                       }} =
                        QuackDB.query(tx, "UPDATE #{table} SET value = value + 1 WHERE id = 1")
             end)

    send(writer.pid, :release_first_writer)
    assert {:ok, :ok} = Task.await(writer)
  end

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
