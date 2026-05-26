defmodule QuackDBDemo do
  def start_connection do
    case System.get_env("QUACKDB_URI") do
      nil ->
        token = "super_secret"
        {:ok, server} = QuackDB.Server.start_link(duckdb: :managed, token: token)
        {:ok, conn} = QuackDB.start_link(uri: QuackDB.Server.uri(server), token: token)
        %{conn: conn, server: server}

      uri ->
        {:ok, conn} = QuackDB.start_link(uri: uri, token: System.get_env("QUACKDB_TOKEN", ""))
        %{conn: conn, server: nil}
    end
  end
end
