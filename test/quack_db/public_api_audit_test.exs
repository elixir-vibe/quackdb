if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.PublicAPIAuditTest do
    use ExUnit.Case, async: true

    test "accepted Ecto helper modules are public and predicate dispatch stays hidden" do
      public_modules = [
        QuackDB.Ecto.Analytics,
        QuackDB.Ecto.Conditionals,
        QuackDB.Ecto.FTS,
        QuackDB.Ecto.Regex,
        QuackDB.Ecto.Series,
        QuackDB.Ecto.Spatial,
        QuackDB.Ecto.Text,
        QuackDB.Ecto.WindowFrames
      ]

      for module <- public_modules do
        assert Code.ensure_loaded?(module)
        refute match?(false, Code.fetch_docs(module))
      end

      assert Code.ensure_loaded?(QuackDB.Ecto.Predicates)
      assert {:docs_v1, _, :elixir, _, :hidden, _, _} = Code.fetch_docs(QuackDB.Ecto.Predicates)
    end

    test "accepted helper names remain available" do
      assert exported_macro?(QuackDB.Ecto.Analytics, :band, 1)
      assert exported_macro?(QuackDB.Ecto.Analytics, :bor, 1)
      assert exported_macro?(QuackDB.Ecto.Analytics, :bxor, 1)
      assert exported_macro?(QuackDB.Ecto.Text, :contains_text, 2)
      assert exported_macro?(QuackDB.Ecto.Spatial, :st_contains, 2)
      assert exported_macro?(QuackDB.Ecto.WindowFrames, :rows_between, 2)
      assert exported_macro?(QuackDB.Ecto.WindowFrames, :range_between, 2)
      assert exported_macro?(QuackDB.Ecto.WindowFrames, :groups_between, 2)
    end

    defp exported_macro?(module, name, arity) do
      {name, arity} in module.__info__(:macros)
    end
  end
end
