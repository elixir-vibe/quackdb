defmodule QuackDB.Ecto.Quote do
  @moduledoc false

  @spec name(atom() | String.t()) :: iodata()
  def name(name) when is_atom(name), do: name |> Atom.to_string() |> name()
  def name(name) when is_integer(name), do: name |> Integer.to_string() |> name()

  def name(name) when is_binary(name) do
    if String.contains?(name, "\"") do
      raise ArgumentError, "bad literal/field/table name #{inspect(name)} (\" is not permitted)"
    end

    [?\", name, ?\"]
  end

  # A dotted prefix names a path, which DuckDB resolves as a nested schema
  # (DuckDB 2.0) or as catalog.schema.
  @spec name(atom() | String.t() | nil, atom() | String.t()) :: iodata()
  def name(nil, name), do: name(name)

  def name(prefix, name) do
    path = prefix |> to_string() |> String.split(".") |> Enum.map(&name/1)
    [Enum.intersperse(path, ?.), ?., name(name)]
  end
end
