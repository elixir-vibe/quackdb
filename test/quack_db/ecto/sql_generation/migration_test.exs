defmodule QuackDB.Ecto.SQLGeneration.MigrationTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.QuackDB.Connection
  alias Ecto.Migration.{Constraint, Index, Reference, Table}

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

  test "generates temporal and decimal defaults" do
    sql =
      {:create, %Table{name: "events"},
       [
         {:add, :amount, :decimal, [default: Decimal.new("12.34")]},
         {:add, :event_date, :date, [default: ~D[2026-05-26]]},
         {:add, :event_time, :time, [default: ~T[12:34:56]]},
         {:add, :occurred_at, :naive_datetime, [default: ~N[2026-05-26 12:34:56]]},
         {:add, :precise_at, :naive_datetime_usec, [default: ~N[2026-05-26 12:34:56.123456]]},
         {:add, :received_at, :utc_datetime, [default: ~U[2026-05-26 12:34:56Z]]},
         {:add, :precise_received_at, :utc_datetime_usec,
          [default: ~U[2026-05-26 12:34:56.123456Z]]}
       ]}
      |> Connection.execute_ddl()
      |> single_sql()

    assert sql ==
             ~s|CREATE TABLE "events" ("amount" DECIMAL DEFAULT 12.34, "event_date" DATE DEFAULT DATE '2026-05-26', "event_time" TIME DEFAULT TIME '12:34:56', "occurred_at" TIMESTAMP DEFAULT TIMESTAMP '2026-05-26 12:34:56', "precise_at" TIMESTAMP DEFAULT TIMESTAMP '2026-05-26 12:34:56.123456', "received_at" TIMESTAMPTZ DEFAULT TIMESTAMPTZ '2026-05-26T12:34:56Z', "precise_received_at" TIMESTAMPTZ DEFAULT TIMESTAMPTZ '2026-05-26T12:34:56.123456Z')|
  end

  test "rejects unsupported default values explicitly" do
    assert_raise QuackDB.Error, ~r/unsupported migration default value/, fn ->
      {:create, %Table{name: "events"}, [{:add, :payload, :string, [default: %{kind: "duck"}]}]}
      |> Connection.execute_ddl()
      |> single_sql()
    end
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

  test "generates constraint DDL" do
    sql =
      {:create, %Constraint{table: "events", name: "positive_score", check: "score >= 0"}}
      |> Connection.execute_ddl()
      |> single_sql()

    assert sql == ~s|ALTER TABLE "events" ADD CONSTRAINT "positive_score" CHECK (score >= 0)|
  end

  test "rejects unsupported table options explicitly" do
    assert_raise QuackDB.Error, ~r/table comments/, fn ->
      {:create, %Table{name: "events", comment: "analytics events"}, []}
      |> Connection.execute_ddl()
      |> single_sql()
    end

    assert_raise QuackDB.Error, ~r/table engine options/, fn ->
      {:create, %Table{name: "events", engine: "MergeTree"}, []}
      |> Connection.execute_ddl()
      |> single_sql()
    end

    assert_raise QuackDB.Error, ~r/raw Ecto table :options/, fn ->
      {:create, %Table{name: "events", options: "WITHOUT ROWID"}, []}
      |> Connection.execute_ddl()
      |> single_sql()
    end
  end

  test "rejects unsupported constraint options explicitly" do
    assert_raise QuackDB.Error, ~r/exclude constraints/, fn ->
      {:create, %Constraint{table: "events", name: "no_overlap", exclude: "gist (id WITH = )"}}
      |> Connection.execute_ddl()
      |> single_sql()
    end
  end

  test "rejects unsupported index options explicitly" do
    assert_raise QuackDB.Error, ~r/concurrent index creation/, fn ->
      {:create,
       %Index{table: "events", name: "events_name_index", columns: [:name], concurrently: true}}
      |> Connection.execute_ddl()
      |> single_sql()
    end

    assert_raise QuackDB.Error, ~r/covering index/, fn ->
      {:create,
       %Index{table: "events", name: "events_name_index", columns: [:name], include: [:score]}}
      |> Connection.execute_ddl()
      |> single_sql()
    end
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
