defmodule QuackDB do
  @moduledoc """
  Remote DuckDB Quack protocol client.

  The initial implementation is intentionally layered so the low-level protocol
  codec can grow independently from the DBConnection and future Ecto adapter
  layers.
  """

  alias QuackDB.Connection

  @type start_option :: {:uri, String.t()} | {:token, String.t()} | {:name, GenServer.name()}

  @spec start_link([start_option]) :: GenServer.on_start()
  def start_link(options) do
    Connection.start_link(options)
  end

  @spec query(GenServer.server(), iodata(), [term()], Keyword.t()) ::
          {:ok, QuackDB.Result.t()} | {:error, QuackDB.Error.t()}
  def query(connection, statement, params \\ [], options \\ []) do
    Connection.query(connection, statement, params, options)
  end
end
