defmodule QuackDB.Result do
  @moduledoc """
  Normalized query result.

  The shape mirrors what `Ecto.Adapters.SQL` expects from DBConnection-backed
  drivers: `rows` and `num_rows` are always present, while `columns`,
  `connection_id`, `messages`, and `metadata` keep Quack-specific result
  information available.
  """

  @type command ::
          :select
          | :insert
          | :update
          | :delete
          | :create
          | :drop
          | :alter
          | :begin
          | :commit
          | :rollback
          | atom()

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

  @affecting_commands [:insert, :update, :delete]
  @schema_commands [:create, :drop, :alter]

  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{command: command, columns: ["Count"], rows: [[count]]} = result)
      when command in @affecting_commands and is_integer(count) and count >= 0 do
    %{result | columns: nil, rows: nil, num_rows: count, metadata: raw_count_metadata(result)}
  end

  def normalize(%__MODULE__{command: command, columns: ["Count"], rows: []} = result)
      when command in @schema_commands do
    %{result | columns: nil, rows: nil, num_rows: 0, metadata: raw_count_metadata(result)}
  end

  def normalize(%__MODULE__{} = result), do: result

  defp raw_count_metadata(result) do
    result.metadata
    |> Map.put(:duckdb_columns, result.columns)
    |> Map.put(:duckdb_rows, result.rows)
  end
end

defimpl Inspect, for: QuackDB.Result do
  import Inspect.Algebra

  def inspect(result, opts) do
    rows_count = QuackDB.Inspect.rows_summary(result.rows)
    preview = QuackDB.Inspect.rows_preview(result.rows)
    needs_more_fetch? = result.metadata[:needs_more_fetch]

    fields = [
      command: result.command,
      columns: result.columns,
      rows: rows_count,
      preview: preview,
      connection_id: QuackDB.Inspect.short_id(result.connection_id),
      needs_more_fetch?: needs_more_fetch?
    ]

    concat(QuackDB.Inspect.container("QuackDB.Result", fields, opts))
  end
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
