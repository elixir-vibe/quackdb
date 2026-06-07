defmodule QuackDB.TestSchemas.MapEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "map_events" do
    field(:id, :integer)
    field(:metadata, :map)
  end
end
