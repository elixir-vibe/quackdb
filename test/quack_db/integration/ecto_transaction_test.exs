defmodule QuackDB.Integration.EctoTransactionTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "Ecto transactions commit through Repo.transaction/1" do
    start_repo!()
    table = "quackdb_ecto_commit_#{System.unique_integer([:positive])}"

    assert {:ok, :committed} =
             QuackDB.IntegrationRepo.transaction(fn ->
               QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER)")
               QuackDB.IntegrationRepo.query!("INSERT INTO #{table} VALUES (1), (2)")
               :committed
             end)

    assert %{rows: [[3]]} = QuackDB.IntegrationRepo.query!("SELECT SUM(id) FROM #{table}")
  end

  test "Ecto Repo.rollback/1 rolls back transaction work" do
    start_repo!()
    table = "quackdb_ecto_rollback_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER)")

    assert {:error, :rolled_back} =
             QuackDB.IntegrationRepo.transaction(fn ->
               QuackDB.IntegrationRepo.query!("INSERT INTO #{table} VALUES (1)")
               QuackDB.IntegrationRepo.rollback(:rolled_back)
             end)

    assert %{rows: [[0]]} = QuackDB.IntegrationRepo.query!("SELECT COUNT(*) FROM #{table}")
  end

  test "Ecto transactions roll back after query errors" do
    start_repo!()
    table = "quackdb_ecto_error_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER)")

    assert {:error, %QuackDB.Error{message: message}} =
             QuackDB.IntegrationRepo.transaction(fn ->
               QuackDB.IntegrationRepo.query!("INSERT INTO #{table} VALUES (1)")

               case QuackDB.IntegrationRepo.query("SELEC broken") do
                 {:error, error} -> QuackDB.IntegrationRepo.rollback(error)
                 {:ok, result} -> flunk("expected query to fail, got: #{inspect(result)}")
               end
             end)

    assert message =~ "syntax error"
    assert %{rows: [[0]]} = QuackDB.IntegrationRepo.query!("SELECT COUNT(*) FROM #{table}")
  end
end
