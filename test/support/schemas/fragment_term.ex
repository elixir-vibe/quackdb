defmodule QuackDB.TestSchemas.FragmentTerm do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "fragment_terms" do
    field(:term_id, :integer)
    field(:fragment_id, :integer)
  end
end
