defmodule QuackDB.Protocol.InferenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias QuackDB.Protocol.DataChunk

  test "integers widen to the smallest type that holds them all" do
    assert types(n: [1, 2]) == [n: "INTEGER"]
    assert types(n: [1, 10_000_000_000]) == [n: "BIGINT"]
    assert types(n: [1, 0x8000_0000_0000_0000]) == [n: "HUGEINT"]

    assert {:error, %QuackDB.Error{code: :invalid_append_type}} =
             infer(n: [1, 0x8000_0000_0000_0000_0000_0000_0000_0000])
  end

  test "integers join floats only while a DOUBLE holds them exactly" do
    assert types(n: [1, 2.5]) == [n: "DOUBLE"]
    assert types(n: [2.5, nil, 1]) == [n: "DOUBLE"]

    assert {:error, %QuackDB.Error{code: :mixed_append_types, message: message}} =
             infer(n: [2.5, 9_007_199_254_740_993])

    assert message =~ "append column n mixes floats with integers"
  end

  test "decimals and integers widen to one DECIMAL" do
    assert types(d: [Decimal.new("1.5"), Decimal.new("123.456"), 7]) == [d: "DECIMAL(6, 3)"]
    assert types(d: [Decimal.new("1E+3")]) == [d: "DECIMAL(4, 0)"]

    assert {:error, %QuackDB.Error{code: :invalid_append_type}} =
             infer(
               d: [Decimal.new("1" <> String.duplicate("0", 30)), Decimal.new("0.0000000001")]
             )
  end

  test "struct fields are the union of every map's keys" do
    assert types(p: [%{a: 1}, %{a: 2.5, b: "x"}, nil]) == [p: ~s|STRUCT("a" DOUBLE, "b" VARCHAR)|]
  end

  test "list elements unify across every list" do
    assert types(tags: [[1], [], [10_000_000_000]]) == [tags: "BIGINT[]"]
  end

  test "row keys missing from the first row still become columns" do
    assert {:ok, [%{name: :a}, %{name: :b}]} =
             DataChunk.columns_from_rows([[a: 1], [a: 2, b: "x"]])
  end

  test "other mixes name the value and how to declare it" do
    for {values, path, kinds} <- [
          {[1, "x"], "n", "integer and string"},
          {[%{a: 1}, 5], "n", "map and integer"},
          {[[1], 5], "n", "list and integer"},
          {[[1, "x"]], "n[]", "integer and string"},
          {[%{a: 1}, %{a: "x"}], "n.a", "integer and string"},
          {[~N[2026-01-01 00:00:00], ~U[2026-01-01 00:00:00Z]], "n",
           "NaiveDateTime and DateTime"},
          {[1.5, Decimal.new("1.5")], "n", "float and Decimal"}
        ] do
      assert {:error, %QuackDB.Error{code: :mixed_append_types, message: message}} =
               infer(n: values)

      assert message =~ "append column #{path} mixes #{kinds} values"
      assert message =~ ":variant"
    end
  end

  property "integers infer INTEGER only when every value fits in 32 bits" do
    integers = one_of([integer(), integer(-0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF)])

    check all(values <- list_of(integer_or_nil(integers), min_length: 1), Enum.any?(values)) do
      fits? = values |> Enum.reject(&is_nil/1) |> Enum.all?(&(&1 in -0x8000_0000..0x7FFF_FFFF))
      assert types(n: values) == [n: if(fits?, do: "INTEGER", else: "BIGINT")]
    end
  end

  defp integer_or_nil(integers), do: one_of([integers, constant(nil)])

  defp infer(columns), do: DataChunk.columns_from_column_values(columns)

  defp types(columns) do
    {:ok, inferred} = infer(columns)

    Enum.map(inferred, fn column ->
      {column.name, column.type |> QuackDB.Protocol.LogicalType.to_sql() |> IO.iodata_to_binary()}
    end)
  end
end
