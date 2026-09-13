defmodule QuackDB.TestSchemas.NestedRecord do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "nested_records" do
    field(:id, :integer, primary_key: true)
    field(:payload, :map)
    field(:payloads, {:array, :map})
    field(:nested_payloads, {:array, {:array, :map}})
    field(:states, {:array, Ecto.Enum}, values: [:queued, :done])
    field(:priorities, {:array, Ecto.Enum}, values: [low: 1, high: 2])
  end
end
