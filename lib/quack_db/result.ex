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

  @doc """
  Converts a row-oriented result into a column-oriented map.

  Duplicate column names are disambiguated with suffixes such as `_2` and `_3`,
  matching `QuackDB.maps/4`.
  """
  @spec to_columns(t()) :: %{String.t() => [term()]}
  def to_columns(%__MODULE__{} = result), do: result |> to_columnar() |> Map.fetch!(:columns)

  @doc """
  Converts a row-oriented result into a `QuackDB.Columns` struct.
  """
  @spec to_columnar(t()) :: QuackDB.Columns.t()
  def to_columnar(%__MODULE__{columns: columns, rows: rows} = result)
      when is_list(columns) and is_list(rows) do
    keys = disambiguate_columns(columns)
    initial = Map.new(keys, &{&1, []})

    columns =
      rows
      |> Enum.reduce(initial, fn row, acc ->
        keys
        |> Enum.zip(row)
        |> Enum.reduce(acc, fn {key, value}, acc -> Map.update!(acc, key, &[value | &1]) end)
      end)
      |> Map.new(fn {key, values} -> {key, Enum.reverse(values)} end)

    %QuackDB.Columns{
      names: keys,
      original_names: result.columns,
      columns: columns,
      num_rows: result.num_rows,
      command: result.command,
      connection_id: result.connection_id,
      messages: result.messages,
      metadata: result.metadata
    }
  end

  def to_columnar(%__MODULE__{} = result) do
    %QuackDB.Columns{
      command: result.command,
      connection_id: result.connection_id,
      messages: result.messages,
      metadata: result.metadata
    }
  end

  @doc false
  @spec disambiguate_columns([String.t()]) :: [String.t()]
  def disambiguate_columns(columns) do
    {columns, _counts} =
      Enum.map_reduce(columns, %{}, fn column, counts ->
        counts = Map.update(counts, column, 1, &(&1 + 1))

        case counts[column] do
          1 -> {column, counts}
          count -> {"#{column}_#{count}", counts}
        end
      end)

    columns
  end

  defp raw_count_metadata(result) do
    result.metadata
    |> Map.put(:duckdb_columns, result.columns)
    |> Map.put(:duckdb_rows, result.rows)
  end
end

defimpl Inspect, for: QuackDB.Result do
  import Inspect.Algebra

  alias QuackDB.Inspect, as: QuackInspect

  def inspect(result, opts) do
    rows_count = QuackInspect.rows_summary(result.rows)
    preview = QuackInspect.rows_preview(result.rows)
    needs_more_fetch? = result.metadata[:needs_more_fetch]

    fields = [
      command: result.command,
      columns: result.columns,
      rows: rows_count,
      preview: preview,
      connection_id: QuackInspect.short_id(result.connection_id),
      needs_more_fetch?: needs_more_fetch?
    ]

    concat(QuackInspect.container("QuackDB.Result", fields, opts))
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
