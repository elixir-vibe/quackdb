defmodule QuackDB.Transport do
  @moduledoc """
  Transport entry point for Quack binary HTTP requests.

  The default implementation uses a Mint-backed stateful connection owned by the DBConnection process.
  """

  @shutdown_timeout 1_000

  def start_link(uri, options \\ []) do
    QuackDB.Transport.Mint.start_link(uri, options)
  end

  def post(%URI{} = uri, body, options) do
    with {:ok, server} <- start_link(uri, options) do
      try do
        QuackDB.Transport.Mint.post(server, uri, body, options)
      after
        GenServer.stop(
          server,
          :normal,
          Keyword.get(options, :shutdown_timeout, @shutdown_timeout)
        )
      end
    end
  end

  def post(server, uri, body, options) do
    QuackDB.Transport.Mint.post(server, uri, body, options)
  end
end
