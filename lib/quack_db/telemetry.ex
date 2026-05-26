defmodule QuackDB.Telemetry do
  @moduledoc false

  @default_prefix [:quackdb]
  @operations [:query, :append, :fetch]

  @spec default_prefix() :: [atom()]
  def default_prefix, do: @default_prefix

  @spec span([atom()], atom(), map(), (-> term())) :: term()
  def span(prefix, operation, metadata, fun)
      when operation in @operations and is_function(fun, 0) do
    :telemetry.span(event(prefix, operation), metadata, fun)
  end

  @spec event([atom()], atom()) :: [atom()]
  def event(prefix, operation) when operation in @operations do
    append_operation(prefix, operation)
  end

  defp append_operation([], operation), do: [operation]
  defp append_operation([head | tail], operation), do: [head | append_operation(tail, operation)]
end
