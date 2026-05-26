defmodule QuackDB.Ecto.SQLGeneration.MigrationTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.QuackDB.Connection
  alias Ecto.Migration.{Index, Reference, Table}

  test "generates create table DDL" do
    sql =
      {:create, %Table{name: "events"},
       [
         {:add, :id, :bigint, [primary_key: true]},
         {:add, :name, :string, [null: false]},
         {:add, :score, :integer, [default: 0]}
       ]}
      |> Connection.execute_ddl()
      |> single_sql()

    assert sql ==
             ~s|CREATE TABLE "events" ("id" BIGINT PRIMARY KEY, "name" VARCHAR NOT NULL, "score" INTEGER DEFAULT 0)|
  end

  test "generates composite primary key and references" do
    sql =
      {:create, %Table{name: "events", primary_key: :composite},
       [
         {:add, :account_id, :integer, [primary_key: true]},
         {:add, :id, :integer, [primary_key: true]},
         {:add, :category_id,
          %Reference{table: "categories", type: :integer, on_delete: :delete_all}, []}
       ]}
      |> Connection.execute_ddl()
      |> single_sql()

    assert sql ==
             ~s|CREATE TABLE "events" ("account_id" INTEGER, "id" INTEGER, "category_id" INTEGER REFERENCES "categories"("id") ON DELETE CASCADE, PRIMARY KEY ("account_id", "id"))|
  end

  test "generates alter table DDL" do
    sql =
      {:alter, %Table{name: "events"}, [{:add, :name, :string, []}, {:remove, :old_name}]}
      |> Connection.execute_ddl()
      |> Enum.map(&IO.iodata_to_binary/1)

    assert sql == [
             ~s|ALTER TABLE "events" ADD COLUMN "name" VARCHAR|,
             ~s|ALTER TABLE "events" DROP COLUMN "old_name"|
           ]
  end

  test "generates index DDL" do
    sql =
      {:create,
       %Index{table: "events", name: "events_name_index", columns: [:name], unique: true}}
      |> Connection.execute_ddl()
      |> single_sql()

    assert sql == ~s|CREATE UNIQUE INDEX "events_name_index" ON "events" ("name")|
  end

  defp single_sql([sql]), do: IO.iodata_to_binary(sql)
end
