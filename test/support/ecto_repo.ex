defmodule QuackDB.EctoRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :quackdb,
    adapter: Ecto.Adapters.QuackDB
end
