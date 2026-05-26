if Code.ensure_loaded?(Table.Reader) do
  defimpl Table.Reader, for: QuackDB.Columns do
    def init(%QuackDB.Columns{names: names, columns: columns, num_rows: num_rows}) do
      data = Enum.map(names, fn name -> Map.fetch!(columns, name) end)
      {:columns, %{columns: names, count: num_rows}, data}
    end
  end
end
