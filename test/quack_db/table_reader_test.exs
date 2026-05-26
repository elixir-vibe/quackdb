if Code.ensure_loaded?(Table.Reader) do
  defmodule QuackDB.TableReaderTest do
    use ExUnit.Case, async: true

    test "reads QuackDB.Columns through Table.Reader" do
      columns = %QuackDB.Columns{
        names: ["id", "name"],
        original_names: ["id", "name"],
        columns: %{"id" => [1, 2], "name" => ["duck", "goose"]},
        num_rows: 2
      }

      assert {:columns, metadata, data} = Table.Reader.init(columns)
      assert metadata == %{columns: ["id", "name"], count: 2}
      assert Enum.map(data, &Enum.to_list/1) == [[1, 2], ["duck", "goose"]]
    end

    test "reads row-shaped QuackDB.Result through Table.Reader" do
      result = %QuackDB.Result{
        columns: ["id", "name"],
        rows: [[1, "duck"], [2, "goose"]],
        num_rows: 2
      }

      assert {:rows, metadata, rows} = Table.Reader.init(result)
      assert metadata == %{columns: ["id", "name"], count: 2}
      assert Enum.to_list(rows) == [[1, "duck"], [2, "goose"]]
    end

    test "non-tabular command results are not readable" do
      assert Table.Reader.init(%QuackDB.Result{command: :insert, num_rows: 2}) == :none
    end
  end
end
