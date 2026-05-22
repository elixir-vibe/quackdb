defmodule QuackDB.Result do
  @moduledoc """
  Normalized query result.

  The shape mirrors what `Ecto.Adapters.SQL` expects from DBConnection-backed
  drivers: `rows` and `num_rows` are always present, while `columns`,
  `connection_id`, `messages`, and `metadata` keep Quack-specific result
  information available.
  """

  @type command :: :select | :insert | :update | :delete | :begin | :commit | :rollback | atom()

  @type t :: %__MODULE__{
          command: command() | nil,
          columns: [String.t()] | nil,
          rows: [[term()]] | nil,
          num_rows: non_neg_integer(),
          connection_id: String.t() | nil,
          messages: [map()] | nil,
          metadata: map()
        }

  defstruct command: nil,
            columns: nil,
            rows: nil,
            num_rows: 0,
            connection_id: nil,
            messages: nil,
            metadata: %{}
end

if Code.ensure_loaded?(Table.Reader) do
  defimpl Table.Reader, for: QuackDB.Result do
    def init(%{columns: columns}) when columns in [nil, []] do
      {:rows, %{columns: [], count: 0}, []}
    end

    def init(%{rows: rows} = result) do
      {columns, _counts} =
        Enum.map_reduce(result.columns, %{}, fn column, counts ->
          counts = Map.update(counts, column, 1, &(&1 + 1))

          case counts[column] do
            1 -> {column, counts}
            count -> {"#{column}_#{count}", counts}
          end
        end)

      {:rows, %{columns: columns, count: result.num_rows}, rows || []}
    end
  end
end
