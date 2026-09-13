defmodule QuackDB.Ecto.TypeMappingTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.QuackDB, as: Adapter
  alias QuackDB.Ecto.Type

  test "map dumpers preserve SQL NULL instead of tagging it as JSON" do
    for type <- [:map, {:map, :integer}, {:array, :map}, {:array, {:map, :integer}}] do
      assert {:ok, nil} = Ecto.Type.adapter_dump(Adapter, type, nil)
    end

    assert {:ok, {:json, %{}}} = Ecto.Type.adapter_dump(Adapter, :map, %{})
  end

  test "nested map types use the appropriate SQL or append representation" do
    for {usage, scalar} <- [migration: :json, append: :varchar] do
      assert Type.column_type!({:array, :map}, usage) == {:list, scalar}
      assert Type.column_type!({:array, {:array, :map}}, usage) == {:list, {:list, scalar}}
    end
  end

  test "parameterized enums are resolved at every array depth" do
    for {values, scalar} <- [{[:queued, :done], :varchar}, {[low: 1, high: 2], :integer}],
        usage <- [:schema, :migration, :append] do
      enum = Ecto.ParameterizedType.init(Ecto.Enum, values: values)
      assert Type.column_type!({:array, enum}, usage) == {:list, scalar}
      assert Type.column_type!({:array, {:array, enum}}, usage) == {:list, {:list, scalar}}
    end
  end
end
