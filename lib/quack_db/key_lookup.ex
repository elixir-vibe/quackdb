defmodule QuackDB.KeyLookup do
  @moduledoc false

  @spec fetch(map() | keyword() | nil, atom() | String.t()) :: term()
  def fetch(nil, _name), do: nil

  def fetch(row, name) when is_list(row) do
    if Keyword.keyword?(row), do: keyword_value(row, name)
  end

  def fetch(row, name) when is_map(row) do
    cond do
      Map.has_key?(row, name) ->
        Map.fetch!(row, name)

      is_atom(name) and Map.has_key?(row, to_string(name)) ->
        Map.fetch!(row, to_string(name))

      is_binary(name) ->
        find_atom_key(row, name)

      true ->
        nil
    end
  end

  def fetch(_row, _name), do: nil

  defp keyword_value(row, name) do
    cond do
      is_atom(name) and Keyword.has_key?(row, name) -> Keyword.fetch!(row, name)
      is_binary(name) -> find_atom_key(row, name)
      true -> nil
    end
  end

  defp find_atom_key(row, name) do
    Enum.find_value(row, fn
      {key, value} when is_atom(key) -> if Atom.to_string(key) == name, do: {:value, value}
      _entry -> nil
    end)
    |> case do
      {:value, value} -> value
      nil -> nil
    end
  end
end
