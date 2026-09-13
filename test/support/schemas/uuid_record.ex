defmodule QuackDB.TestSchemas.UUIDRecord do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "uuid_records" do
    field(:external_id, Ecto.UUID)
    field(:parent_id, :binary_id)
    field(:related_ids, {:array, :binary_id})
    field(:external_ids, {:array, Ecto.UUID})
  end
end
