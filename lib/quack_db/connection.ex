defmodule QuackDB.Connection do
  @moduledoc false

  use GenServer

  alias QuackDB.Error

  @type option :: {:uri, String.t()} | {:token, String.t()} | {:name, GenServer.name()}

  @spec start_link([option]) :: GenServer.on_start()
  def start_link(options) do
    {gen_server_options, connection_options} = Keyword.split(options, [:name])
    GenServer.start_link(__MODULE__, connection_options, gen_server_options)
  end

  @spec query(GenServer.server(), iodata(), [term()], Keyword.t()) :: {:error, Error.t()}
  def query(connection, statement, params, options) do
    GenServer.call(
      connection,
      {:query, statement, params, options},
      Keyword.get(options, :timeout, 15_000)
    )
  end

  @impl true
  def init(options) do
    {:ok, Map.new(options)}
  end

  @impl true
  def handle_call({:query, _statement, _params, _options}, _from, state) do
    error = Error.new(:not_implemented, "Quack query execution is not implemented yet")
    {:reply, {:error, error}, state}
  end
end
