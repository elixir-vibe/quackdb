defmodule QuackDB.IntegrationRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :quackdb,
    adapter: Ecto.Adapters.QuackDB
end

defmodule QuackDB.QuackServerCase do
  @moduledoc false

  def start_connection! do
    {uri, token} = server_uri_and_token!()
    ExUnit.Callbacks.start_supervised!({QuackDB, uri: uri, token: token})
  end

  def start_repo! do
    {uri, token} = server_uri_and_token!()

    Application.put_env(:quackdb, QuackDB.IntegrationRepo,
      uri: uri,
      token: token,
      pool_size: 1,
      log: false
    )

    ExUnit.Callbacks.start_supervised!(QuackDB.IntegrationRepo)
  end

  defp server_uri_and_token! do
    case System.get_env("QUACKDB_TEST_URI") do
      nil -> start_local_server!()
      uri -> {uri, System.get_env("QUACKDB_TEST_TOKEN", "")}
    end
  end

  defp start_local_server! do
    token = "quackdb_integration_#{System.unique_integer([:positive])}"
    port = 20_000 + rem(System.unique_integer([:positive]), 30_000)
    endpoint = "quack:localhost:#{port}"
    uri = "http://[::1]:#{port}"

    options = [
      duckdb: test_duckdb(),
      endpoint: endpoint,
      uri: uri,
      token: token,
      database: ":memory:",
      wait_timeout: 10_000
    ]

    child_spec = Supervisor.child_spec({QuackDB.Server, options}, id: {:quackdb_server, port})
    ExUnit.Callbacks.start_supervised!(child_spec)

    {uri, token}
  end

  defp test_duckdb do
    case System.get_env("QUACKDB_TEST_DUCKDB") do
      nil -> System.find_executable("duckdb") || :managed
      "managed" -> :managed
      path -> path
    end
  end
end
