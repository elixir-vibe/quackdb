defmodule QuackDB.Telemetry do
  @moduledoc false

  @events %{
    query: [:quackdb, :query],
    append: [:quackdb, :append],
    fetch: [:quackdb, :fetch]
  }

  @spec span(atom(), map(), (-> term())) :: term()
  def span(operation, metadata, fun) when is_function(fun, 0) do
    :telemetry.span(event(operation), metadata, fun)
  end

  @spec event(atom()) :: [atom()]
  def event(operation), do: Map.fetch!(@events, operation)
end
