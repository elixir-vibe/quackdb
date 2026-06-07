defmodule QuackDB.ResultMapper do
  @moduledoc false

  @spec rows_to_structs(QuackDB.Result.t(), module()) :: [struct()]
  def rows_to_structs(%QuackDB.Result{columns: columns, rows: rows}, module)
      when is_list(columns) and is_list(rows) do
    fields = Map.keys(struct!(module)) -- [:__struct__]
    keys = Enum.map(columns, &normalize_key/1)

    Enum.map(rows, fn row ->
      keys
      |> Enum.zip(row)
      |> Map.new()
      |> Map.take(fields)
      |> then(&struct!(module, &1))
    end)
  end

  def rows_to_structs(%QuackDB.Result{}, _module), do: []

  defp normalize_key(key) when is_binary(key) do
    key
    |> Macro.underscore()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> key
  end
end
