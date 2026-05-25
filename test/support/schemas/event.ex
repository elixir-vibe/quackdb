defmodule QuackDB.TestSchemas.Event do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "events" do
    field(:id, :integer)
    field(:name, :string)
    field(:score, :integer)
    field(:category_id, :integer)
  end
end
