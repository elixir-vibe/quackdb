defmodule QuackDB.TestSchemas.TypedEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "typed_events" do
    field(:id, :integer)
    field(:amount, :decimal)
    field(:event_date, :date)
    field(:event_time, :time)
    field(:occurred_at, :naive_datetime)
    field(:occurred_tz, :utc_datetime)
    field(:status, Ecto.Enum, values: [:queued, :done])
    field(:priority, Ecto.Enum, values: [low: 1, high: 2])
    field(:tags, {:array, :string})
  end
end
