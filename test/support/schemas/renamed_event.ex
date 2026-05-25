defmodule QuackDB.TestSchemas.RenamedEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "renamed_events" do
    field(:id, :integer)
    field(:name, :string, source: :event_name)
  end
end
