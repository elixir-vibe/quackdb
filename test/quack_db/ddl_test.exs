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

  defmodule UnsupportedSchema do
    use Ecto.Schema

    @primary_key false
    schema "events" do
      field(:payload, :map)
    end
  end

  test "create_table reports unsupported Ecto schema fields" do
    assert_raise ArgumentError,
                 ~r/unsupported Ecto schema type for QuackDB.DDLTest.UnsupportedSchema.payload: :map/,
                 fn -> QuackDB.DDL.create_table(UnsupportedSchema, temporary: true) end
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

  test "create_table builds CTAS statements" do
    assert QuackDB.DDL.create_table("docs",
             as: ["SELECT * FROM ", QuackDB.Source.parquet("docs.parquet")],
             temporary: true,
             if_not_exists: true
           )
           |> IO.iodata_to_binary() ==
             ~s|CREATE TEMP TABLE IF NOT EXISTS "docs" AS SELECT * FROM read_parquet('docs.parquet')|
  end

  test "create_table builds CTAS with selected aliases" do
    import Ecto.Query

    query =
      from(doc in "docs",
        select: %{document_id: doc.id, heading: selected_as(doc.title, :heading)}
      )

    assert QuackDB.DDL.create_table("docs_copy", as: query)
           |> IO.iodata_to_binary() ==
             ~s|CREATE TABLE "docs_copy" AS SELECT q0."id" AS "document_id", q0."title" AS "heading" FROM "docs" AS q0|
  end

  test "create_table rejects CTAS from parameterized Ecto queries" do
    import Ecto.Query

    query = from(doc in "docs", where: doc.id == ^1, select: doc.id)

    assert_raise ArgumentError, ~r/does not support parameterized Ecto queries/, fn ->
      QuackDB.DDL.create_table("docs_copy", as: query)
    end
  end

  test "create_table builds CTAS statements from Ecto queries" do
    import Ecto.Query

    source = QuackDB.Source.parquet("docs.parquet")

    query =
      from(doc in source,
        select: %{id: doc.id, title: doc.title, body: doc.body}
      )

    assert QuackDB.DDL.create_table("docs", as: query, temporary: true)
           |> IO.iodata_to_binary() ==
             ~s|CREATE TEMP TABLE "docs" AS SELECT q0."id" AS "id", q0."title" AS "title", q0."body" AS "body" FROM read_parquet('docs.parquet') AS q0|
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
