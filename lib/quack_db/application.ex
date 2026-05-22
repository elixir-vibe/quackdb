defmodule QuackDB.Application do
  @moduledoc """
  OTP application entry point for QuackDB.

  Starts the supervision tree used by the package. Connection processes are
  started by callers through `QuackDB.start_link/1` or child specs.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: QuackDB.Supervisor)
  end
end
