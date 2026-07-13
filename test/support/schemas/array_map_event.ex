defmodule QuackDB.TestSchemas.ArrayMapEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "array_map_events" do
    field(:id, :integer)
    field(:metadata, :map)
    field(:errors, {:array, :map})
  end
end
