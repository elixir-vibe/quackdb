defmodule QuackDB.TestSchemas.ParameterRecord do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "parameter_records" do
    field(:body, :string)
    field(:tags, {:array, :string})
    field(:nested, {:array, {:array, :integer}})
    field(:occurred_at, :naive_datetime_usec)
    field(:occurred_tz, :utc_datetime_usec)
    field(:payload, :binary)
    field(:attachments, {:array, :binary})
  end
end
