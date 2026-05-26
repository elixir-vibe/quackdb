defmodule QuackDB.Integration.Ecto.MigrationTest do
  use ExUnit.Case, async: false
  import QuackDB.QuackServerCase

  alias Ecto.Adapters.QuackDB.Connection
  alias Ecto.Migration.{Index, Reference, Table}

  @moduletag :integration

  test "generated migration DDL runs against DuckDB" do
    start_repo!()
    table = "quackdb_ecto_migration_#{System.unique_integer([:positive, :monotonic])}"
    index = "#{table}_name_index"

    execute_ddl!({:drop_if_exists, %Table{name: table}, :restrict})

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

  test "generated temporal and decimal defaults run against DuckDB" do
    start_repo!()
    table = "quackdb_ecto_migration_defaults_#{System.unique_integer([:positive, :monotonic])}"

    execute_ddl!({:drop_if_exists, %Table{name: table}, :restrict})

    execute_ddl!(
      {:create, %Table{name: table},
       [
         {:add, :id, :integer, []},
         {:add, :amount, :decimal, [default: Decimal.new("12.34")]},
         {:add, :event_date, :date, [default: ~D[2026-05-26]]},
         {:add, :event_time, :time, [default: ~T[12:34:56]]},
         {:add, :occurred_at, :naive_datetime, [default: ~N[2026-05-26 12:34:56]]},
         {:add, :received_at, :utc_datetime, [default: ~U[2026-05-26 12:34:56Z]]}
       ]}
    )

    assert {1, nil} = QuackDB.IntegrationRepo.insert_all(table, [[id: 1]])

    assert %{rows: [[1, amount, ~D[2026-05-26], event_time, occurred_at, received_at]]} =
             QuackDB.IntegrationRepo.query!(
               "SELECT id, amount, event_date, event_time, occurred_at, received_at FROM #{table}"
             )

    assert Decimal.equal?(amount, Decimal.new("12.34"))
    assert Time.compare(event_time, ~T[12:34:56]) == :eq
    assert NaiveDateTime.compare(occurred_at, ~N[2026-05-26 12:34:56]) == :eq
    assert DateTime.compare(received_at, ~U[2026-05-26 12:34:56Z]) == :eq

    execute_ddl!({:drop, %Table{name: table}, :restrict})
  end

  test "generated rename and modify DDL runs against DuckDB" do
    start_repo!()
    table = "quackdb_ecto_migration_rename_#{System.unique_integer([:positive, :monotonic])}"
    renamed = "#{table}_renamed"

    execute_ddl!(
      {:create, %Table{name: table},
       [
         {:add, :id, :integer, []},
         {:add, :name, :string, []},
         {:add, :score, :integer, []}
       ]}
    )

    assert {1, nil} = QuackDB.IntegrationRepo.insert_all(table, [[id: 1, name: "duck", score: 7]])

    execute_ddl!({:rename, %Table{name: table}, %Table{name: renamed}})
    execute_ddl!({:rename, %Table{name: renamed}, :name, :title})
    execute_ddl!({:alter, %Table{name: renamed}, [{:modify, :score, :bigint, []}]})

    assert %{rows: [[1, "duck", 7]]} =
             QuackDB.IntegrationRepo.query!("SELECT id, title, score FROM #{renamed}")

    assert %{rows: [["BIGINT"]]} =
             QuackDB.IntegrationRepo.query!(
               "SELECT data_type FROM information_schema.columns WHERE table_name = ? AND column_name = 'score'",
               [renamed]
             )

    execute_ddl!({:drop, %Table{name: renamed}, :restrict})
  end

  test "generated reference and composite primary key DDL runs against DuckDB" do
    start_repo!()

    categories =
      "quackdb_ecto_migration_categories_#{System.unique_integer([:positive, :monotonic])}"

    events = "quackdb_ecto_migration_events_#{System.unique_integer([:positive, :monotonic])}"

    execute_ddl!(
      {:create_if_not_exists, %Table{name: categories},
       [{:add, :id, :integer, [primary_key: true]}]}
    )

    execute_ddl!(
      {:create_if_not_exists, %Table{name: events, primary_key: :composite},
       [
         {:add, :account_id, :integer, [primary_key: true]},
         {:add, :id, :integer, [primary_key: true]},
         {:add, :category_id, %Reference{table: categories, type: :integer}, []}
       ]}
    )

    assert %{rows: [[events]]} =
             QuackDB.IntegrationRepo.query!(
               "SELECT table_name FROM information_schema.tables WHERE table_name = ?",
               [events]
             )

    execute_ddl!({:drop_if_exists, %Table{name: events}, :restrict})
    execute_ddl!({:drop_if_exists, %Table{name: categories}, :restrict})
  end

  defp execute_ddl!(command) do
    command
    |> Connection.execute_ddl()
    |> Enum.each(&QuackDB.IntegrationRepo.query!(IO.iodata_to_binary(&1)))
  end
end
