defmodule QuackDB.DDLTest do
  use ExUnit.Case, async: true

  defmodule EventSchema do
    use Ecto.Schema

    @primary_key false
    schema "events" do
      field(:id, :integer)
      field(:name, :string)
      field(:score, :float)
    end
  end

  test "create_table builds DDL from an Ecto schema" do
    assert EventSchema
           |> QuackDB.DDL.create_table(temporary: true)
           |> IO.iodata_to_binary() ==
             ~s|CREATE TEMP TABLE "events" ("id" INTEGER, "name" VARCHAR, "score" DOUBLE)|
  end

  test "create_table builds regular table DDL" do
    assert QuackDB.DDL.create_table("events", id: :integer, name: :varchar)
           |> IO.iodata_to_binary() == ~S[CREATE TABLE "events" ("id" INTEGER, "name" VARCHAR)]
  end

  test "create_table supports temporary and if_not_exists options" do
    assert QuackDB.DDL.create_table(
             :events,
             [payload: :json, occurred_at: :timestamp],
             temporary: true,
             if_not_exists: true
           )
           |> IO.iodata_to_binary() ==
             ~S[CREATE TEMP TABLE IF NOT EXISTS "events" ("payload" JSON, "occurred_at" TIMESTAMP)]
  end

  test "create_table supports richer DuckDB types and column options" do
    assert QuackDB.DDL.create_table("metrics", [
             {:id, :integer, primary_key: true},
             {:name, {:varchar, 64}, null: false},
             {:amount, {:decimal, 18, 2}, default: Decimal.new("0.00")},
             {:tags, {:list, :varchar}},
             {:scores, {:array, :integer, 3}},
             {:attrs, {:map, :varchar, :integer}},
             {:payload, {:struct, kind: :varchar, count: :integer}}
           ])
           |> IO.iodata_to_binary() ==
             ~s|CREATE TABLE "metrics" ("id" INTEGER PRIMARY KEY, "name" VARCHAR(64) NOT NULL, "amount" DECIMAL(18, 2) DEFAULT 0.00, "tags" VARCHAR[], "scores" INTEGER[3], "attrs" MAP(VARCHAR, INTEGER), "payload" STRUCT("kind" VARCHAR, "count" INTEGER))|
  end

  test "drop_table supports if_exists" do
    assert QuackDB.DDL.drop_table("events", if_exists: true) |> IO.iodata_to_binary() ==
             ~S[DROP TABLE IF EXISTS "events"]
  end

  test "quotes identifiers" do
    assert QuackDB.DDL.create_table("weird\"table", "weird\"column": :integer)
           |> IO.iodata_to_binary() ==
             ~S[CREATE TABLE "weird""table" ("weird""column" INTEGER)]
  end

  test "requires at least one column" do
    assert_raise ArgumentError, ~r/expected at least one column/, fn ->
      QuackDB.DDL.create_table("empty", [])
    end
  end
end
