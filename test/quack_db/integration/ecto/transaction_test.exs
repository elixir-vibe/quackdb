defmodule QuackDB.Integration.Ecto.TransactionTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase
  import QuackDB.TestHelper

  @moduletag :integration

  test "Ecto transactions commit through Repo.transaction/1" do
    start_repo!()
    table = unique_table("quackdb_ecto_commit")

    assert {:ok, :committed} =
             QuackDB.IntegrationRepo.transaction(fn ->
               create_table!(QuackDB.IntegrationRepo, table, id: :integer)
               insert_rows!(QuackDB.IntegrationRepo, table, [[1], [2]])
               :committed
             end)

    assert %{rows: [[3]]} = QuackDB.IntegrationRepo.query!("SELECT SUM(id) FROM #{table}")
  end

  test "Ecto Repo.rollback/1 rolls back transaction work" do
    start_repo!()
    table = unique_table("quackdb_ecto_rollback")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer)

    assert {:error, :rolled_back} =
             QuackDB.IntegrationRepo.transaction(fn ->
               insert_rows!(QuackDB.IntegrationRepo, table, [[1]])
               QuackDB.IntegrationRepo.rollback(:rolled_back)
             end)

    assert %{rows: [[0]]} = QuackDB.IntegrationRepo.query!("SELECT COUNT(*) FROM #{table}")
  end

  test "Ecto transactions roll back after query errors" do
    start_repo!()
    table = unique_table("quackdb_ecto_error")

    create_table!(QuackDB.IntegrationRepo, table, id: :integer)

    assert {:error, %QuackDB.Error{message: message}} =
             QuackDB.IntegrationRepo.transaction(fn ->
               insert_rows!(QuackDB.IntegrationRepo, table, [[1]])

               case QuackDB.IntegrationRepo.query("SELEC broken") do
                 {:error, error} -> QuackDB.IntegrationRepo.rollback(error)
                 {:ok, result} -> flunk("expected query to fail, got: #{inspect(result)}")
               end
             end)

    assert message =~ "syntax error"
    assert %{rows: [[0]]} = QuackDB.IntegrationRepo.query!("SELECT COUNT(*) FROM #{table}")
  end
end
