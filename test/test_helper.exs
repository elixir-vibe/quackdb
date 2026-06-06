skip_integration? = System.get_env("QUACKDB_SKIP_INTEGRATION") == "1"
external_uri = System.get_env("QUACKDB_TEST_URI")
test_duckdb = System.get_env("QUACKDB_TEST_DUCKDB")
local_duckdb = System.find_executable("duckdb")
integration_available? = external_uri || test_duckdb || local_duckdb

if integration_available? && !skip_integration? do
  unless external_uri do
    token = "quackdb_integration_#{System.unique_integer([:positive])}"
    port = 20_000 + rem(System.unique_integer([:positive]), 30_000)
    endpoint = "quack:localhost:#{port}"
    uri = "http://[::1]:#{port}"

    duckdb =
      case test_duckdb do
        nil -> local_duckdb
        "managed" -> :managed
        path -> path
      end

    {:ok, server} =
      QuackDB.Server.start_link(
        duckdb: duckdb,
        endpoint: endpoint,
        uri: uri,
        token: token,
        database: ":memory:",
        wait_timeout: 10_000,
        poll_interval: 10
      )

    System.put_env("QUACKDB_TEST_URI", uri)
    System.put_env("QUACKDB_TEST_TOKEN", token)

    ExUnit.after_suite(fn _result ->
      if Process.alive?(server), do: GenServer.stop(server)
    end)
  end

  ExUnit.start()
else
  ExUnit.start(exclude: [integration: true])
end
