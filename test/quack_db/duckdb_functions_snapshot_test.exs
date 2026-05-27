defmodule QuackDB.DuckDBFunctionsSnapshotTest do
  use ExUnit.Case, async: true

  @snapshot_path Application.app_dir(:quackdb, "priv/duckdb_functions/current.exs")

  test "snapshot tracks analytical helper candidates from DuckDB runtime catalog" do
    assert File.exists?(@snapshot_path)

    {snapshot, _binding} = Code.eval_file(@snapshot_path)

    assert snapshot.duckdb_version =~ "v"
    assert Enum.any?(snapshot.functions, &(&1.name == "median" and &1.type == :aggregate))

    candidates = Map.new(snapshot.helper_candidates, &{&1.name, &1})

    assert candidates["median"].arities == [1]
    assert candidates["quantile_cont"].arities == [2]
    assert candidates["weighted_avg"].arities == [2]
    assert candidates["fsum"].types == [:aggregate]

    assert [%{parameter_type_specs: [:double], return_type_spec: :double}] =
             candidates["fsum"].overloads

    skipped_candidates = Map.new(snapshot.skipped_helper_candidates, &{&1.name, &1})
    refute Map.has_key?(candidates, "sum_no_overflow")

    assert skipped_candidates["sum_no_overflow"].reason ==
             "DuckDB reports this function as internal-use-only at execution time"

    assert Enum.any?(
             skipped_candidates["sum_no_overflow"].overloads,
             &(&1.return_type_spec == :hugeint)
           )
  end

  test "regex Ecto helper manifest matches DuckDB snapshot arities" do
    {snapshot, _binding} = Code.eval_file(@snapshot_path)

    functions =
      snapshot.functions
      |> Enum.filter(&(&1.type == :scalar))
      |> Enum.group_by(& &1.name)

    for %{name: name, arities: arities} <- QuackDB.Ecto.Regex.__regex_helpers__() do
      helper = Atom.to_string(name)
      function_arities = functions |> Map.fetch!(helper) |> Enum.map(& &1.arity)

      for arity <- arities do
        assert arity in function_arities,
               "expected #{helper}/#{arity} to be backed by DuckDB #{helper}/#{arity}"
      end
    end
  end

  test "simple Ecto helper manifest matches DuckDB snapshot arities" do
    {snapshot, _binding} = Code.eval_file(@snapshot_path)
    candidates = Map.new(snapshot.helper_candidates, &{&1.name, &1})

    for %{name: name, sql: sql, arity: arity} <-
          QuackDB.Ecto.Analytics.__simple_fragment_helpers__() do
      helper = Atom.to_string(name)
      candidate = Map.fetch!(candidates, sql)

      assert arity in candidate.arities,
             "expected #{helper}/#{arity} to be backed by DuckDB #{sql}/#{arity}"
    end
  end
end
