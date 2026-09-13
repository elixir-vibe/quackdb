defmodule QuackDB.Ecto.UUIDTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.QuackDB, as: Adapter

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  test "loads canonical and binary UUIDs through Ecto types" do
    for type <- [:binary_id, Ecto.UUID], value <- [@uuid, Ecto.UUID.dump!(@uuid)] do
      assert {:ok, @uuid} = Ecto.Type.adapter_load(Adapter, type, value)
      assert {:ok, [@uuid, nil]} = Ecto.Type.adapter_load(Adapter, {:array, type}, [value, nil])
      assert {:ok, nil} = Ecto.Type.adapter_load(Adapter, type, nil)
      assert {:ok, []} = Ecto.Type.adapter_load(Adapter, {:array, type}, [])
    end
  end

  test "maps UUID schema and array types for DDL and native appends" do
    for usage <- [:migration, :append, :schema], type <- [:binary_id, Ecto.UUID] do
      assert QuackDB.Ecto.Type.column_type!(type, usage) == :uuid
      assert QuackDB.Ecto.Type.column_type!({:array, type}, usage) == {:list, :uuid}
    end
  end

  test "rejects malformed UUIDs without raising" do
    for type <- [:binary_id, Ecto.UUID], value <- ["not a UUID", "", 123] do
      assert :error = Ecto.Type.adapter_load(Adapter, type, value)
      assert :error = Ecto.Type.adapter_load(Adapter, {:array, type}, [value])
    end
  end
end
