defmodule QuackDB do
  @moduledoc """
  Remote DuckDB Quack protocol client.

  The public API is backed by `DBConnection` so it can grow into an Ecto adapter
  without changing the lower-level protocol codec.
  """

  alias QuackDB.Query
  alias QuackDB.Stream

  @type start_option :: {:uri, String.t()} | {:token, String.t()} | {:name, GenServer.name()}

  @spec start_link([start_option]) :: GenServer.on_start()
  def start_link(options) do
    QuackDB.DBConnection.start_link(options)
  end

  @spec child_spec([start_option]) :: Supervisor.child_spec()
  def child_spec(options) do
    QuackDB.DBConnection.child_spec(options)
  end

  @spec query(DBConnection.conn(), iodata(), [term()], Keyword.t()) ::
          {:ok, QuackDB.Result.t()} | {:error, Exception.t()}
  def query(connection, statement, params \\ [], options \\ []) do
    query = %Query{statement: statement}

    case DBConnection.prepare_execute(connection, query, params, options) do
      {:ok, _query, result} -> {:ok, result}
      {:error, _error} = error -> error
    end
  end

  @spec query!(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: QuackDB.Result.t()
  def query!(connection, statement, params \\ [], options \\ []) do
    case query(connection, statement, params, options) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @spec prepare(DBConnection.conn(), iodata(), Keyword.t()) ::
          {:ok, Query.t()} | {:error, Exception.t()}
  def prepare(connection, statement, options \\ []) do
    DBConnection.prepare(connection, %Query{statement: statement}, options)
  end

  @spec prepare_execute(DBConnection.conn(), iodata(), [term()], Keyword.t()) ::
          {:ok, Query.t(), QuackDB.Result.t()} | {:error, Exception.t()}
  def prepare_execute(connection, statement, params \\ [], options \\ []) do
    DBConnection.prepare_execute(connection, %Query{statement: statement}, params, options)
  end

  @spec stream(DBConnection.conn(), iodata(), [term()], Keyword.t()) :: Stream.t()
  def stream(connection, statement, params \\ [], options \\ []) do
    %Stream{
      conn: connection,
      query: %Query{statement: statement},
      params: params,
      options: options
    }
  end
end
