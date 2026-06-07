defmodule QuackDB.SourceRef do
  @moduledoc false

  @type t :: module() | atom() | String.t() | {atom() | String.t(), atom() | String.t()}

  @spec name(t()) :: String.t()
  def name({prefix, source}), do: Enum.map_join([prefix, source], ".", &part/1)

  def name(source) when is_atom(source) do
    if Code.ensure_loaded?(source) and function_exported?(source, :__schema__, 1) do
      schema_name(source)
    else
      Atom.to_string(source)
    end
  end

  def name(source) when is_binary(source), do: source

  defp schema_name(schema) do
    case apply(schema, :__schema__, [:prefix]) do
      nil -> apply(schema, :__schema__, [:source])
      prefix -> name({prefix, apply(schema, :__schema__, [:source])})
    end
  rescue
    FunctionClauseError -> apply(schema, :__schema__, [:source])
  end

  defp part(value) when is_atom(value), do: Atom.to_string(value)
  defp part(value) when is_binary(value), do: value
end
