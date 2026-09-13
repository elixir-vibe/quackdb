defmodule QuackDB.TestSchemas.CustomUUIDRecord do
  @moduledoc false
  use Ecto.Schema

  defmodule UUID do
    @moduledoc false
    use Ecto.Type

    def type, do: :uuid
    defdelegate cast(value), to: Ecto.UUID
    defdelegate dump(value), to: Ecto.UUID
    defdelegate load(value), to: Ecto.UUID
    def autogenerate, do: "01890f3e-7c00-7000-8000-000000000001"
  end

  defmodule Version7 do
    @moduledoc false
    use Ecto.Type

    def type, do: :uuid
    def cast({:uuid_v7, _} = value), do: {:ok, value}
    def cast(_), do: :error
    def dump({:uuid_v7, value}), do: Ecto.UUID.dump(value)
    def dump(_), do: :error

    def load(<<_::48, 7::4, _::76>> = value) do
      {:ok, uuid} = Ecto.UUID.load(value)
      {:ok, {:uuid_v7, uuid}}
    end

    def load(_), do: :error
  end

  @primary_key {:id, UUID, autogenerate: true}
  schema "custom_uuid_records" do
    field(:other_id, UUID)
    field(:ids, {:array, UUID})
    field(:checked_id, Version7)
    field(:checked_ids, {:array, Version7})
  end
end
