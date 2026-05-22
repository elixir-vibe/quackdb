defmodule QuackDB.Stream do
  @moduledoc """
  Lazy stream returned by `QuackDB.stream/4`.
  """

  @type t :: %__MODULE__{
          conn: DBConnection.conn(),
          query: QuackDB.Query.t(),
          params: [term()],
          options: Keyword.t()
        }

  defstruct [:conn, :query, :params, :options]
end

defimpl Inspect, for: QuackDB.Stream do
  import Inspect.Algebra

  def inspect(stream, opts) do
    fields = [
      statement: QuackDB.Inspect.truncate(stream.query.statement),
      params: length(stream.params || []),
      options: stream.options
    ]

    concat(QuackDB.Inspect.container("QuackDB.Stream", fields, opts))
  end
end

defimpl Enumerable, for: QuackDB.Stream do
  def reduce(%QuackDB.Stream{} = stream, acc, fun) do
    %QuackDB.Stream{conn: conn, query: query, params: params, options: options} = stream

    options = Keyword.put(options, :function, :prepare_open)

    db_stream = %DBConnection.PrepareStream{
      conn: conn,
      query: query,
      params: params,
      opts: options
    }

    DBConnection.reduce(db_stream, acc, fn
      %QuackDB.Result{rows: []}, acc -> {:cont, acc}
      result, acc -> fun.(result, acc)
    end)
  end

  def member?(_stream, _value), do: {:error, __MODULE__}
  def count(_stream), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end
