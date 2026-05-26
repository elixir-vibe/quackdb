defmodule QuackDB.TestSchemas.RenamedBinaryEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "renamed_binary_events" do
    field(:id, :binary_id, source: :event_uuid)
    field(:payload, :binary)
  end
end
