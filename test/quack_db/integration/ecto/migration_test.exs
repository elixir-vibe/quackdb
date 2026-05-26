defmodule QuackDB.Integration.Ecto.MigrationTest do
  use ExUnit.Case, async: false
  import QuackDB.QuackServerCase

  alias Ecto.Adapters.QuackDB.Connection
  alias Ecto.Migration.{Index, Table}

  @moduletag :integration

  test "generated migration DDL runs against DuckDB" do
    start_repo!()
    table = "quackdb_ecto_migration_#{System.unique_integer([:positive])}"
    index = "#{table}_name_index"

    execute_ddl!(
      {:create, %Table{name: table},
       [
         {:add, :id, :integer, [primary_key: true]},
         {:add, :name, :string, [null: false]},
         {:add, :score, :integer, [default: 0]}
       ]}
    )

    execute_ddl!({:create, %Index{table: table, name: index, columns: [:name]}})
    execute_ddl!({:alter, %Table{name: table}, [{:add, :active, :boolean, [default: true]}]})

    assert {1, nil} = QuackDB.IntegrationRepo.insert_all(table, [[id: 1, name: "duck"]])

    assert %{rows: [[1, "duck", 0, true]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, name, score, active FROM #{table}")

    execute_ddl!({:drop, %Index{name: index}})
    execute_ddl!({:drop, %Table{name: table}, :restrict})
  end

  defp execute_ddl!(command) do
    command
    |> Connection.execute_ddl()
    |> Enum.each(&QuackDB.IntegrationRepo.query!(IO.iodata_to_binary(&1)))
  end
end
