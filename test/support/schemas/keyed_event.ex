defmodule QuackDB.TestSchemas.KeyedEvent do
  @moduledoc false

  use Ecto.Schema

  schema "keyed_events" do
    field(:name, :string)
    field(:score, :integer)
  end
end
