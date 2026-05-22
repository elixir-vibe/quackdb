defmodule QuackDB.Query do
  @moduledoc """
  Query metadata used by the DBConnection driver.
  """

  @type t :: %__MODULE__{
          statement: iodata(),
          columns: [String.t()] | nil,
          result_types: [term()] | nil,
          result_uuid: integer() | nil
        }

  defstruct [:statement, :columns, :result_types, :result_uuid]
end

defimpl DBConnection.Query, for: QuackDB.Query do
  def parse(%QuackDB.Query{} = query, _options) do
    %{query | statement: IO.iodata_to_binary(query.statement)}
  end

  def describe(%QuackDB.Query{} = query, _options), do: query

  def encode(_query, params, _options), do: params

  def decode(_query, %QuackDB.Result{rows: nil} = result, _options), do: result

  def decode(_query, %QuackDB.Result{rows: rows} = result, options) do
    %{result | rows: decode_rows(rows, Keyword.get(options, :decode_mapper))}
  end

  defp decode_rows(rows, nil), do: rows
  defp decode_rows(rows, mapper), do: Enum.map(rows, mapper)
end

defimpl Inspect, for: QuackDB.Query do
  import Inspect.Algebra

  def inspect(query, opts) do
    fields = [
      statement: QuackDB.Inspect.truncate(query.statement),
      columns: query.columns,
      result_uuid: query.result_uuid
    ]

    concat(QuackDB.Inspect.container("QuackDB.Query", fields, opts))
  end
end

defimpl String.Chars, for: QuackDB.Query do
  def to_string(%QuackDB.Query{statement: statement}) do
    IO.iodata_to_binary(statement)
  end
end
