if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.PublicAPIAuditTest do
    use ExUnit.Case, async: true

    test "accepted Ecto helper modules are public and predicate dispatch stays hidden" do
      public_modules = [
        QuackDB.Ecto.Analytics,
        QuackDB.Ecto.Conditionals,
        QuackDB.Ecto.FTS,
        QuackDB.Ecto.List,
        QuackDB.Ecto.Map,
        QuackDB.Ecto.Regex,
        QuackDB.Ecto.Series,
        QuackDB.Ecto.Spatial,
        QuackDB.Ecto.Star,
        QuackDB.Ecto.Struct,
        QuackDB.Ecto.Text,
        QuackDB.Ecto.WindowFrames
      ]

      for module <- public_modules do
        assert Code.ensure_loaded?(module)
        refute match?(false, Code.fetch_docs(module))
      end

      assert Code.ensure_loaded?(QuackDB.Ecto.Predicates)
      assert {:docs_v1, _, :elixir, _, :hidden, _, _} = Code.fetch_docs(QuackDB.Ecto.Predicates)

      assert Code.ensure_loaded?(QuackDB.Ecto.Lambda)
      assert {:docs_v1, _, :elixir, _, :hidden, _, _} = Code.fetch_docs(QuackDB.Ecto.Lambda)
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
      assert exported_macro?(QuackDB.Ecto.List, :contains_list, 2)
      assert exported_macro?(QuackDB.Ecto.List, :has_any, 2)
      assert exported_macro?(QuackDB.Ecto.List, :has_all, 2)
      assert exported_macro?(QuackDB.Ecto.List, :list_length, 1)
      assert exported_macro?(QuackDB.Ecto.List, :list_filter, 2)
      assert exported_macro?(QuackDB.Ecto.List, :list_transform, 2)
      assert exported_macro?(QuackDB.Ecto.List, :list_reduce, 2)
      assert exported_macro?(QuackDB.Ecto.List, :list_reduce, 3)
      assert exported_macro?(QuackDB.Ecto.List, :extract, 2)
      assert exported_macro?(QuackDB.Ecto.List, :slice, 3)
      assert exported_macro?(QuackDB.Ecto.List, :slice, 4)
      assert exported_macro?(QuackDB.Ecto.List, :sort, 1)
      assert exported_macro?(QuackDB.Ecto.List, :intersect_list, 2)
      assert exported_macro?(QuackDB.Ecto.List, :unnest, 1)
      assert exported_macro?(QuackDB.Ecto.Star, :columns, 1)
      assert exported_macro?(QuackDB.Ecto.Map, :contains_map, 2)
      assert exported_macro?(QuackDB.Ecto.Map, :map_keys, 1)
      assert exported_macro?(QuackDB.Ecto.Map, :map_values, 1)
      assert exported_macro?(QuackDB.Ecto.Map, :map_extract_value, 2)
      assert exported_macro?(QuackDB.Ecto.Struct, :contains_struct, 2)
      assert exported_macro?(QuackDB.Ecto.Struct, :struct_extract, 2)
      assert exported_macro?(QuackDB.Ecto.Struct, :struct_values, 1)
    end

    defp exported_macro?(module, name, arity) do
      {name, arity} in module.__info__(:macros)
    end
  end
end
