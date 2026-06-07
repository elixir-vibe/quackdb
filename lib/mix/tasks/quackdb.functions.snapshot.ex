defmodule Mix.Tasks.Quackdb.Functions.Snapshot do
  @moduledoc """
  Writes a DuckDB function-catalog snapshot for QuackDB maintainer audits.

      mix quackdb.functions.snapshot
      mix quackdb.functions.snapshot --uri http://localhost:9494 --token super_secret
      mix quackdb.functions.snapshot --output priv/duckdb_functions/current.exs

  The snapshot is a checked-in Elixir term used to compare QuackDB's curated
  analytical helpers against DuckDB's runtime catalog. Normal package
  compilation does not require a running DuckDB server.
  """

  use Mix.Task

  @shortdoc "Writes a DuckDB function-catalog snapshot"
  @default_output "priv/duckdb_functions/current.exs"
  @function_types [:aggregate, :macro, :scalar]
  @function_type_names Map.new(@function_types, &{Atom.to_string(&1), &1})
  @candidate_types [:aggregate, :macro]
  @skip_prefix_reasons [
    {"__internal_", "DuckDB internal generated function"},
    {"duckdb_", "DuckDB catalog/helper namespace"},
    {"DuckDB_", "DuckDB extension metadata function"},
    {"ST_", "spatial extension function; audit in QuackDB.Ecto.Spatial instead"}
  ]
  @skip_reasons %{
    "avg" => "covered by Ecto.Query.API.avg/1",
    "coalesce" => "covered by Ecto.Query.API.coalesce/2",
    "count" => "covered by Ecto.Query.API.count/0,1,2",
    "count_star" => "covered by Ecto.Query.API.count/0",
    "countif" => "prefer Ecto filter(count(...), predicate)",
    "date_part" => "implemented by QuackDB.Ecto.Analytics.date_part/2 with atom-part handling",
    "date_trunc" => "implemented by QuackDB.Ecto.Analytics.date_trunc/2 with atom-part handling",
    "array_agg" => "prefer DuckDB list/1 helper name used by DuckDB documentation",
    "current_catalog" => "catalog/session macro, not an analytical expression helper",
    "current_database" => "catalog/session macro, not an analytical expression helper",
    "current_query" => "catalog/session macro, not an analytical expression helper",
    "current_role" => "catalog/session macro, not an analytical expression helper",
    "current_schema" => "catalog/session macro, not an analytical expression helper",
    "current_schemas" => "catalog/session macro, not an analytical expression helper",
    "current_user" => "catalog/session macro, not an analytical expression helper",
    "json_contains" => "implemented by QuackDB.Ecto.Analytics.json_contains/2",
    "json_extract" =>
      "implemented by QuackDB.Ecto.Analytics.json_extract/2 with path-list handling",
    "json_extract_path" => "Ecto JSON access lowers to json_extract_string paths",
    "json_extract_path_text" => "Ecto JSON access lowers to json_extract_string paths",
    "json_extract_string" =>
      "implemented by QuackDB.Ecto.Analytics.json_extract_string/2 with path-list handling",
    "json_exists" =>
      "implemented by QuackDB.Ecto.Analytics.json_exists/2 with path-list handling",
    "first" =>
      "name is too broad for the imported Ecto helper surface; first_value/1 covers window use",
    "last" =>
      "name is too broad for the imported Ecto helper surface; last_value/1 covers window use",
    "listagg" => "string_agg/2,3 is the canonical helper name",
    "max" => "covered by Ecto.Query.API.max/1",
    "min" => "covered by Ecto.Query.API.min/1",
    "sum" => "covered by Ecto.Query.API.sum/1",
    "sum_no_overflow" => "DuckDB reports this function as internal-use-only at execution time",
    "wavg" => "weighted_avg/2 is the canonical helper name"
  }

  @impl Mix.Task
  def run(args) do
    {options, _argv, invalid} =
      OptionParser.parse(args,
        strict: [uri: :string, token: :string, output: :string],
        aliases: [o: :output]
      )

    case invalid do
      [] -> snapshot(options)
      invalid -> Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  defp snapshot(options) do
    Mix.Task.run("app.start")

    uri = Keyword.get(options, :uri) || System.fetch_env!("QUACKDB_URI")
    token = Keyword.get(options, :token, System.get_env("QUACKDB_TOKEN", ""))
    output = Keyword.get(options, :output, @default_output)

    {:ok, conn} = QuackDB.start_link(uri: uri, token: token)

    %QuackDB.Result{rows: [[version]]} = QuackDB.query!(conn, "SELECT version()")

    %QuackDB.Result{rows: rows} =
      QuackDB.query!(conn, """
      SELECT
        function_name,
        function_type,
        parameters,
        parameter_types,
        return_type,
        varargs,
        has_side_effects,
        internal,
        stability,
        categories
      FROM duckdb_functions()
      WHERE function_type IN ('scalar', 'aggregate', 'macro')
      ORDER BY function_type, function_name, parameter_types
      """)

    functions =
      rows
      |> Enum.map(&function_entry/1)
      |> Enum.sort_by(&{&1.type, &1.name, &1.arity, &1.parameter_types})

    {helper_candidates, skipped_helper_candidates} = helper_candidate_report(functions)

    snapshot = %{
      duckdb_version: version,
      generated_by: "mix quackdb.functions.snapshot",
      functions: functions,
      helper_candidates: helper_candidates,
      skipped_helper_candidates: skipped_helper_candidates
    }

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, snapshot_source(snapshot))
    Mix.shell().info("Wrote #{output} with #{length(rows)} functions from DuckDB #{version}")
  end

  defp function_entry([
         name,
         type,
         parameters,
         parameter_types,
         return_type,
         varargs,
         side_effects,
         internal,
         stability,
         categories
       ]) do
    %{
      name: name,
      type: normalize_function_type(type),
      arity: length(parameter_types || []),
      parameters: parameters || [],
      parameter_types: parameter_types || [],
      parameter_type_specs: Enum.map(parameter_types || [], &type_spec/1),
      return_type: return_type,
      return_type_spec: type_spec(return_type),
      varargs: varargs,
      has_side_effects: side_effects,
      internal: internal,
      stability: stability,
      categories: categories || []
    }
  end

  defp helper_candidate_report(functions) do
    {candidate_entries, skipped_entries} =
      functions
      |> Enum.filter(&(&1.type in @candidate_types))
      |> Enum.split_with(&(skip_reason(&1) == nil))

    {summarize_entries(candidate_entries), summarize_skipped_entries(skipped_entries)}
  end

  defp summarize_entries(entries) do
    entries
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, entries} ->
      %{
        name: name,
        types: entries |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort(),
        arities: entries |> Enum.map(& &1.arity) |> Enum.uniq() |> Enum.sort(),
        categories: entries |> Enum.flat_map(& &1.categories) |> Enum.uniq() |> Enum.sort(),
        overloads: overloads(entries)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp summarize_skipped_entries(entries) do
    entries
    |> Enum.group_by(&{&1.name, skip_reason(&1)})
    |> Enum.map(fn {{name, reason}, entries} ->
      %{
        name: name,
        reason: reason,
        types: entries |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort(),
        arities: entries |> Enum.map(& &1.arity) |> Enum.uniq() |> Enum.sort(),
        overloads: overloads(entries)
      }
    end)
    |> Enum.sort_by(&{&1.reason, &1.name})
  end

  defp skip_reason(function) do
    cond do
      function.has_side_effects ->
        "function has side effects"

      function.varargs != nil ->
        "function uses varargs; helper arity is not fixed"

      reason = @skip_reasons[function.name] ->
        reason

      reason = prefixed_skip_reason(function.name) ->
        reason

      operator_name?(function.name) ->
        "operator syntax; prefer Ecto operators or explicit fragments"

      true ->
        nil
    end
  end

  defp overloads(entries) do
    entries
    |> Enum.map(fn entry ->
      %{
        type: entry.type,
        arity: entry.arity,
        parameter_types: entry.parameter_types,
        parameter_type_specs: entry.parameter_type_specs,
        return_type: entry.return_type,
        return_type_spec: entry.return_type_spec
      }
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.type, &1.arity, &1.parameter_types, inspect(&1.return_type_spec)})
  end

  defp type_spec(nil), do: nil

  defp type_spec(type) when is_binary(type) do
    case QuackDB.Type.from_sql(type) do
      {:ok, spec} -> spec
      {:error, {:unsupported_sql_type, type}} -> {:raw_type, type, []}
    end
  end

  defp normalize_function_type(type) when is_binary(type) do
    case @function_type_names do
      %{^type => function_type} -> function_type
      _types -> Mix.raise("unknown DuckDB function type in snapshot: #{inspect(type)}")
    end
  end

  defp prefixed_skip_reason(name) do
    Enum.find_value(@skip_prefix_reasons, fn {prefix, reason} ->
      if String.starts_with?(name, prefix), do: reason
    end)
  end

  defp operator_name?(name), do: Regex.match?(~r/^\W+$/, name)

  defp snapshot_source(snapshot) do
    formatted =
      snapshot
      |> inspect(limit: :infinity, printable_limit: :infinity, charlists: :as_lists)
      |> Code.format_string!()

    ["# Generated by mix quackdb.functions.snapshot.\n\n", formatted, "\n"]
  end
end
