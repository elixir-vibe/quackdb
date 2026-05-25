defmodule QuackDB.IntegrationRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :quackdb,
    adapter: Ecto.Adapters.QuackDB
end

defmodule QuackDB.QuackServerCase do
  @moduledoc false

  def start_connection! do
    uri = System.fetch_env!("QUACKDB_TEST_URI")
    token = System.get_env("QUACKDB_TEST_TOKEN", "")

    ExUnit.Callbacks.start_supervised!({QuackDB, uri: uri, token: token})
  end

  def start_repo! do
    Application.put_env(:quackdb, QuackDB.IntegrationRepo,
      uri: System.fetch_env!("QUACKDB_TEST_URI"),
      token: System.get_env("QUACKDB_TEST_TOKEN", ""),
      pool_size: 1,
      log: false
    )

    ExUnit.Callbacks.start_supervised!(QuackDB.IntegrationRepo)
  end
end
