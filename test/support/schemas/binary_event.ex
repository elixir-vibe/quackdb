defmodule QuackDB.TestSchemas.BinaryEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "binary_events" do
    field(:id, :binary_id)
    field(:payload, :binary)
  end
end
