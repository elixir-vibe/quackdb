if Code.ensure_loaded?(Ecto.Query.API) and Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule QuackDB.Ecto.Analytics do
    @moduledoc """
    DuckDB analytical expression helpers for Ecto queries.

    These macros wrap DuckDB-specific SQL functions in `Ecto.Query.API.fragment/1`
    so analytical queries can stay in Ecto's query DSL instead of scattering raw
    fragment strings across application code.

        import Ecto.Query
        import QuackDB.Ecto.Analytics

        from(event in "events",
          group_by: event.category,
          select: %{
            category: event.category,
            median_score: median(event.score),
            p95_score: quantile_cont(event.score, 0.95),
            scores: list(event.score)
          }
        )

    Helpers only build expressions. DuckDB clauses that are not representable in
    Ecto's AST, such as `PIVOT`, `UNPIVOT`, `QUALIFY`, and `GROUPING SETS`,
    should still be sent as raw SQL.
    """

    @simple_fragment_helpers [
      %{
        name: :approx_count_distinct,
        sql: "approx_count_distinct",
        arity: 1,
        class: :approximate_aggregate
      },
      %{name: :approx_quantile, sql: "approx_quantile", arity: 2, class: :approximate_aggregate},
      %{name: :approx_top_k, sql: "approx_top_k", arity: 2, class: :approximate_aggregate},
      %{name: :any_value, sql: "any_value", arity: 1, class: :aggregate},
      %{name: :band, sql: "bit_and", arity: 1, class: :bitwise_aggregate},
      %{name: :bor, sql: "bit_or", arity: 1, class: :bitwise_aggregate},
      %{name: :bxor, sql: "bit_xor", arity: 1, class: :bitwise_aggregate},
      %{name: :bitstring_agg, sql: "bitstring_agg", arity: 1, class: :bitstring_aggregate},
      %{name: :bitstring_agg, sql: "bitstring_agg", arity: 3, class: :bitstring_aggregate},
      %{name: :bool_and, sql: "bool_and", arity: 1, class: :boolean_aggregate},
      %{name: :bool_or, sql: "bool_or", arity: 1, class: :boolean_aggregate},
      %{name: :median, sql: "median", arity: 1, class: :aggregate},
      %{name: :quantile_cont, sql: "quantile_cont", arity: 2, class: :aggregate},
      %{name: :quantile_disc, sql: "quantile_disc", arity: 2, class: :aggregate},
      %{name: :arg_max, sql: "arg_max", arity: 2, class: :aggregate},
      %{name: :arg_max, sql: "arg_max", arity: 3, class: :aggregate},
      %{name: :arg_min, sql: "arg_min", arity: 2, class: :aggregate},
      %{name: :arg_min, sql: "arg_min", arity: 3, class: :aggregate},
      %{name: :corr, sql: "corr", arity: 2, class: :statistical_aggregate},
      %{name: :stddev, sql: "stddev", arity: 1, class: :statistical_aggregate},
      %{name: :variance, sql: "variance", arity: 1, class: :statistical_aggregate},
      %{name: :favg, sql: "favg", arity: 1, class: :numeric_aggregate},
      %{name: :fsum, sql: "fsum", arity: 1, class: :numeric_aggregate},
      %{name: :product, sql: "product", arity: 1, class: :numeric_aggregate},
      %{name: :mode, sql: "mode", arity: 1, class: :aggregate},
      %{name: :weighted_avg, sql: "weighted_avg", arity: 2, class: :numeric_aggregate},
      %{name: :skewness, sql: "skewness", arity: 1, class: :statistical_aggregate},
      %{name: :kurtosis, sql: "kurtosis", arity: 1, class: :statistical_aggregate},
      %{name: :kurtosis_pop, sql: "kurtosis_pop", arity: 1, class: :statistical_aggregate},
      %{name: :sem, sql: "sem", arity: 1, class: :statistical_aggregate},
      %{name: :geometric_mean, sql: "geometric_mean", arity: 1, class: :numeric_aggregate},
      %{name: :covar_pop, sql: "covar_pop", arity: 2, class: :statistical_aggregate},
      %{name: :covar_samp, sql: "covar_samp", arity: 2, class: :statistical_aggregate},
      %{name: :regr_slope, sql: "regr_slope", arity: 2, class: :statistical_aggregate},
      %{name: :regr_intercept, sql: "regr_intercept", arity: 2, class: :statistical_aggregate},
      %{name: :regr_count, sql: "regr_count", arity: 2, class: :statistical_aggregate},
      %{name: :regr_r2, sql: "regr_r2", arity: 2, class: :statistical_aggregate},
      %{name: :regr_sxx, sql: "regr_sxx", arity: 2, class: :statistical_aggregate},
      %{name: :regr_sxy, sql: "regr_sxy", arity: 2, class: :statistical_aggregate},
      %{name: :regr_syy, sql: "regr_syy", arity: 2, class: :statistical_aggregate},
      %{name: :entropy, sql: "entropy", arity: 1, class: :statistical_aggregate},
      %{name: :mad, sql: "mad", arity: 1, class: :statistical_aggregate},
      %{name: :histogram, sql: "histogram", arity: 1, class: :histogram_aggregate},
      %{name: :histogram_exact, sql: "histogram_exact", arity: 2, class: :histogram_aggregate},
      %{
        name: :reservoir_quantile,
        sql: "reservoir_quantile",
        arity: 2,
        class: :approximate_aggregate
      },
      %{
        name: :reservoir_quantile,
        sql: "reservoir_quantile",
        arity: 3,
        class: :approximate_aggregate
      },
      %{name: :stddev_pop, sql: "stddev_pop", arity: 1, class: :statistical_aggregate},
      %{name: :var_pop, sql: "var_pop", arity: 1, class: :statistical_aggregate},
      %{name: :var_samp, sql: "var_samp", arity: 1, class: :statistical_aggregate}
    ]

    @doc false
    def __simple_fragment_helpers__, do: @simple_fragment_helpers

    @doc "Runs DuckDB `SUMMARIZE` for an Ecto queryable using the `:all` query operation."
    def summarize(repo, queryable), do: summarize(repo, :all, queryable, [])

    def summarize(repo, queryable, options) when is_list(options) do
      summarize(repo, :all, queryable, options)
    end

    @doc "Runs DuckDB `SUMMARIZE` for an Ecto queryable using the given Ecto SQL operation."
    def summarize(repo, operation, queryable)
        when operation in [:all, :update_all, :delete_all] do
      summarize(repo, operation, queryable, [])
    end

    def summarize(repo, operation, queryable, options)
        when operation in [:all, :update_all, :delete_all] do
      {sql, params} = Ecto.Adapters.SQL.to_sql(operation, repo, queryable)
      Ecto.Adapters.SQL.query(repo, ["SUMMARIZE ", sql], params, options)
    end

    @doc "Runs DuckDB `SUMMARIZE` for an Ecto queryable and raises on error."
    def summarize!(repo, queryable), do: summarize!(repo, :all, queryable, [])

    def summarize!(repo, queryable, options) when is_list(options) do
      summarize!(repo, :all, queryable, options)
    end

    @doc "Runs DuckDB `SUMMARIZE` for an Ecto queryable using the given Ecto SQL operation and raises on error."
    def summarize!(repo, operation, queryable)
        when operation in [:all, :update_all, :delete_all] do
      summarize!(repo, operation, queryable, [])
    end

    def summarize!(repo, operation, queryable, options)
        when operation in [:all, :update_all, :delete_all] do
      {sql, params} = Ecto.Adapters.SQL.to_sql(operation, repo, queryable)
      Ecto.Adapters.SQL.query!(repo, ["SUMMARIZE ", sql], params, options)
    end

    for %{name: name, sql: sql, arity: arity} <- @simple_fragment_helpers do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      fragment_sql =
        IO.iodata_to_binary([sql, "(", Enum.map_join(1..arity, ", ", fn _ -> "?" end), ")"])

      defmacro unquote(name)(unquote_splicing(arguments)) do
        simple_fragment(unquote(fragment_sql), [unquote_splicing(arguments)])
      end
    end

    defp simple_fragment(sql, arguments) do
      quote do
        fragment(unquote(sql), unquote_splicing(arguments))
      end
    end

    defmacro list(expression) do
      quote do
        fragment("list(?)", unquote(expression))
      end
    end

    defmacro list(expression, options) when is_list(options) do
      ordered_aggregate("list", [expression], options)
    end

    defmacro string_agg(expression, separator) do
      quote do
        fragment("string_agg(?, ?)", unquote(expression), unquote(separator))
      end
    end

    defmacro string_agg(expression, separator, options) when is_list(options) do
      ordered_aggregate("string_agg", [expression, separator], options)
    end

    defmacro json_extract(expression, path) when is_list(path) do
      quote do
        fragment("json_extract(?, ?)", unquote(expression), unquote(json_path!(path)))
      end
    end

    defmacro json_extract(expression, path) do
      quote do
        fragment("json_extract(?, ?)", unquote(expression), unquote(path))
      end
    end

    defmacro json_extract_string(expression, path) when is_list(path) do
      quote do
        fragment("json_extract_string(?, ?)", unquote(expression), unquote(json_path!(path)))
      end
    end

    defmacro json_extract_string(expression, path) do
      quote do
        fragment("json_extract_string(?, ?)", unquote(expression), unquote(path))
      end
    end

    defmacro json_exists(expression, path) when is_list(path) do
      quote do
        fragment("json_exists(?, ?)", unquote(expression), unquote(json_path!(path)))
      end
    end

    defmacro json_exists(expression, path) do
      quote do
        fragment("json_exists(?, ?)", unquote(expression), unquote(path))
      end
    end

    defmacro json_contains(expression, value) do
      quote do
        fragment("json_contains(?, ?)", unquote(expression), unquote(value))
      end
    end

    defmacro date_trunc(part, timestamp) when is_atom(part) do
      sql = IO.iodata_to_binary(["date_trunc(", date_part_literal!(part), ", ?)"])

      quote do
        fragment(unquote(sql), unquote(timestamp))
      end
    end

    defmacro date_trunc(part, timestamp) do
      quote do
        fragment("date_trunc(?, ?)", unquote(part), unquote(timestamp))
      end
    end

    defmacro date_part(part, timestamp) when is_atom(part) do
      sql = IO.iodata_to_binary(["date_part(", date_part_literal!(part), ", ?)"])

      quote do
        fragment(unquote(sql), unquote(timestamp))
      end
    end

    defmacro date_part(part, timestamp) do
      quote do
        fragment("date_part(?, ?)", unquote(part), unquote(timestamp))
      end
    end

    defmacro equi_width_bins(min, max, bin_count, nice \\ true) do
      quote do
        fragment(
          "equi_width_bins(?, ?, ?, ?)",
          unquote(min),
          unquote(max),
          unquote(bin_count),
          unquote(nice)
        )
      end
    end

    defp ordered_aggregate(function, arguments, options) do
      order_by = Keyword.fetch!(options, :order_by)
      orders = List.wrap(order_by)
      sql = ordered_aggregate_sql(function, length(arguments), orders)
      args = arguments ++ Enum.map(orders, &order_expression!/1)

      quote do
        fragment(unquote(sql), unquote_splicing(args))
      end
    end

    defp ordered_aggregate_sql(function, argument_count, orders) do
      [
        function,
        "(",
        placeholders(argument_count),
        " ORDER BY ",
        order_placeholders(orders),
        ")"
      ]
      |> IO.iodata_to_binary()
    end

    defp placeholders(count), do: Enum.map_join(1..count, ", ", fn _ -> "?" end)

    defp order_placeholders(orders) do
      orders
      |> Enum.map(fn order -> ["? ", order_direction!(order)] end)
      |> Enum.intersperse(", ")
    end

    defp order_expression!({direction, expression})
         when direction in [
                :asc,
                :desc,
                :asc_nulls_first,
                :asc_nulls_last,
                :desc_nulls_first,
                :desc_nulls_last
              ],
         do: expression

    defp order_expression!(expression), do: expression

    defp order_direction!({:asc, _expression}), do: "ASC"
    defp order_direction!({:desc, _expression}), do: "DESC"
    defp order_direction!({:asc_nulls_first, _expression}), do: "ASC NULLS FIRST"
    defp order_direction!({:asc_nulls_last, _expression}), do: "ASC NULLS LAST"
    defp order_direction!({:desc_nulls_first, _expression}), do: "DESC NULLS FIRST"
    defp order_direction!({:desc_nulls_last, _expression}), do: "DESC NULLS LAST"
    defp order_direction!(_expression), do: "ASC"

    defp date_part_literal!(part) do
      part
      |> date_part_name!()
      |> QuackDB.SQL.literal!()
    end

    defp date_part_name!(part)
         when part in [
                :year,
                :quarter,
                :month,
                :week,
                :day,
                :dayofweek,
                :dow,
                :isodow,
                :dayofyear,
                :doy,
                :hour,
                :minute,
                :second,
                :millisecond,
                :microsecond,
                :epoch
              ] do
      Atom.to_string(part)
    end

    defp date_part_name!(part) do
      raise ArgumentError, "unsupported date part: #{inspect(part)}"
    end

    defp json_path!(path) do
      ["$", Enum.map(path, &json_path_segment!/1)]
      |> IO.iodata_to_binary()
    end

    defp json_path_segment!(segment) when is_atom(segment),
      do: json_path_segment!(Atom.to_string(segment))

    defp json_path_segment!(segment) when is_binary(segment) do
      if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, segment) do
        [".", segment]
      else
        ["[", QuackDB.SQL.literal!(segment), "]"]
      end
    end

    defp json_path_segment!(segment) when is_integer(segment) and segment >= 0 do
      ["[", Integer.to_string(segment), "]"]
    end

    defp json_path_segment!(segment) do
      raise ArgumentError, "unsupported JSON path segment: #{inspect(segment)}"
    end

    defmacro time_bucket(%Duration{} = interval, timestamp) do
      quote do
        fragment(
          unquote(["time_bucket(", QuackDB.SQL.literal!(interval), ", ?)"]),
          unquote(timestamp)
        )
      end
    end

    defmacro time_bucket(interval, timestamp) do
      quote do
        fragment("time_bucket(?::INTERVAL, ?)", unquote(interval), unquote(timestamp))
      end
    end

    defmacro time_bucket(%Duration{} = interval, timestamp, options) when is_list(options) do
      {_kind, anchor} = time_bucket_anchor!(options)

      case sql_literal(anchor, __CALLER__) do
        {:ok, anchor_sql} ->
          quote do
            fragment(
              unquote([
                "time_bucket(",
                QuackDB.SQL.literal!(interval),
                ", ?, ",
                anchor_sql,
                ")"
              ]),
              unquote(timestamp)
            )
          end

        :error ->
          quote do
            fragment(
              unquote(["time_bucket(", QuackDB.SQL.literal!(interval), ", ?, ?)"]),
              unquote(timestamp),
              unquote(anchor)
            )
          end
      end
    end

    defmacro time_bucket(interval, timestamp, options) when is_list(options) do
      {_kind, anchor} = time_bucket_anchor!(options)

      quote do
        fragment(
          "time_bucket(?::INTERVAL, ?, ?)",
          unquote(interval),
          unquote(timestamp),
          unquote(anchor)
        )
      end
    end

    defp sql_literal(value, caller) do
      value
      |> Macro.expand(caller)
      |> QuackDB.SQL.literal()
      |> case do
        {:ok, literal} -> {:ok, literal}
        {:error, _reason} -> :error
      end
    end

    defp time_bucket_anchor!(options) do
      present = Enum.filter([:origin, :offset], &Keyword.has_key?(options, &1))

      case present do
        [kind] -> {kind, Keyword.fetch!(options, kind)}
        [] -> raise ArgumentError, "time_bucket/3 expects :origin or :offset"
        _ -> raise ArgumentError, "time_bucket/3 accepts either :origin or :offset, not both"
      end
    end
  end
end
