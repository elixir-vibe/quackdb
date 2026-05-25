defmodule QuackDB.TypeTest do
  use ExUnit.Case, async: true

  test "renders scalar aliases" do
    assert QuackDB.Type.to_sql(:boolean) == "BOOLEAN"
    assert QuackDB.Type.to_sql(:bool) == "BOOLEAN"
    assert QuackDB.Type.to_sql(:integer) == "INTEGER"
    assert QuackDB.Type.to_sql(:int) == "INTEGER"
    assert QuackDB.Type.to_sql(:string) == "VARCHAR"
    assert QuackDB.Type.to_sql(:timestamp_tz) == "TIMESTAMPTZ"
  end

  test "renders parameterized and nested types" do
    assert QuackDB.Type.to_sql({:varchar, 64}) |> IO.iodata_to_binary() == "VARCHAR(64)"
    assert QuackDB.Type.to_sql({:decimal, 18, 2}) |> IO.iodata_to_binary() == "DECIMAL(18, 2)"
    assert QuackDB.Type.to_sql({:list, :integer}) |> IO.iodata_to_binary() == "INTEGER[]"
    assert QuackDB.Type.to_sql({:array, :integer, 3}) |> IO.iodata_to_binary() == "INTEGER[3]"

    assert QuackDB.Type.to_sql({:map, :varchar, :integer}) |> IO.iodata_to_binary() ==
             "MAP(VARCHAR, INTEGER)"

    assert QuackDB.Type.to_sql({:struct, kind: :varchar, count: :integer})
           |> IO.iodata_to_binary() == ~S[STRUCT("kind" VARCHAR, "count" INTEGER)]
  end

  test "passes through raw type strings" do
    assert QuackDB.Type.to_sql("ENUM ('duck', 'goose')") == "ENUM ('duck', 'goose')"
  end

  test "quotes identifiers" do
    assert QuackDB.Type.quote_identifier(~s(weird"name)) |> IO.iodata_to_binary() ==
             ~S["weird""name"]
  end

  test "rejects unsupported types" do
    assert_raise ArgumentError, ~r/unsupported DuckDB column type/, fn ->
      QuackDB.Type.to_sql(:made_up)
    end
  end
end
