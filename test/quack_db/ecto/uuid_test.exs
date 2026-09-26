defmodule QuackDB.Ecto.UUIDTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.QuackDB, as: Adapter
  alias QuackDB.TestSchemas.CustomUUIDRecord.{UUID, Version7}

  @uuid "550e8400-e29b-41d4-a716-446655440000"

  test "loads canonical and binary UUIDs through Ecto types" do
    for type <- [:binary_id, Ecto.UUID], value <- [@uuid, Ecto.UUID.dump!(@uuid)] do
      assert {:ok, @uuid} = Ecto.Type.adapter_load(Adapter, type, value)
      assert {:ok, [@uuid, nil]} = Ecto.Type.adapter_load(Adapter, {:array, type}, [value, nil])
      assert {:ok, nil} = Ecto.Type.adapter_load(Adapter, type, nil)
      assert {:ok, []} = Ecto.Type.adapter_load(Adapter, {:array, type}, [])
    end
  end

  test "dumps UUIDs tagged, so bytes that happen to be valid UTF-8 are never sent as text" do
    ascii = "41414141-4141-4141-4141-414141414141"

    # Dumps take canonical strings, as Ecto.UUID.dump/1 does; loads accept bytes too.
    for type <- [:binary_id, Ecto.UUID, UUID] do
      assert {:ok, {:uuid, ^ascii}} = Ecto.Type.adapter_dump(Adapter, type, ascii)

      assert {:ok, [{:uuid, ^ascii}, nil]} =
               Ecto.Type.adapter_dump(Adapter, {:array, type}, [ascii, nil])

      assert {:ok, nil} = Ecto.Type.adapter_dump(Adapter, type, nil)
    end

    assert {:ok, {:uuid, uuid}} =
             Ecto.Type.adapter_dump(Adapter, Version7, {:uuid_v7, UUID.autogenerate()})

    assert uuid == UUID.autogenerate()
    assert :error = Ecto.Type.adapter_dump(Adapter, :binary_id, "not a UUID")
  end

  test "maps UUID schema and array types for DDL and native appends" do
    for usage <- [:migration, :append, :schema], type <- [:binary_id, Ecto.UUID] do
      assert QuackDB.Ecto.Type.column_type!(type, usage) == :uuid
      assert QuackDB.Ecto.Type.column_type!({:array, type}, usage) == {:list, :uuid}
    end
  end

  test "custom UUID loaders receive binary values and retain their application representation" do
    uuid = UUID.autogenerate()

    for value <- [uuid, Ecto.UUID.dump!(uuid)] do
      assert {:ok, ^uuid} = Ecto.Type.adapter_load(Adapter, UUID, value)
      assert {:ok, {:uuid_v7, ^uuid}} = Ecto.Type.adapter_load(Adapter, Version7, value)

      assert {:ok, [{:uuid_v7, ^uuid}, nil]} =
               Ecto.Type.adapter_load(Adapter, {:array, Version7}, [value, nil])

      assert {:ok, [^uuid, nil]} = Ecto.Type.adapter_load(Adapter, {:array, UUID}, [value, nil])
    end

    for type <- [UUID, Version7] do
      assert {:ok, nil} = Ecto.Type.adapter_load(Adapter, type, nil)
      assert {:ok, []} = Ecto.Type.adapter_load(Adapter, {:array, type}, [])
    end
  end

  test "custom UUID validation is not bypassed for otherwise valid UUIDs" do
    for value <- [@uuid, Ecto.UUID.dump!(@uuid)] do
      assert :error = Ecto.Type.adapter_load(Adapter, Version7, value)
      assert :error = Ecto.Type.adapter_load(Adapter, {:array, Version7}, [value])
    end
  end

  test "rejects malformed UUIDs without raising" do
    for type <- [:binary_id, Ecto.UUID, UUID, Version7], value <- ["not a UUID", "", 123] do
      assert :error = Ecto.Type.adapter_load(Adapter, type, value)
      assert :error = Ecto.Type.adapter_load(Adapter, {:array, type}, [value])
    end
  end
end
