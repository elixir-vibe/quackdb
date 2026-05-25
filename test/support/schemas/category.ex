defmodule QuackDB.TestSchemas.Category do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "categories" do
    field(:id, :integer)
    field(:name, :string)
  end
end
