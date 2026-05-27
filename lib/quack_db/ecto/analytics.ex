if Code.ensure_loaded?(Ecto.Query.API) do
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

    defmacro median(expression) do
      quote do
        fragment("median(?)", unquote(expression))
      end
    end

    defmacro quantile_cont(expression, quantile) do
      quote do
        fragment("quantile_cont(?, ?)", unquote(expression), unquote(quantile))
      end
    end

    defmacro quantile_disc(expression, quantile) do
      quote do
        fragment("quantile_disc(?, ?)", unquote(expression), unquote(quantile))
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

    defmacro arg_max(argument, value) do
      quote do
        fragment("arg_max(?, ?)", unquote(argument), unquote(value))
      end
    end

    defmacro arg_max(argument, value, count) do
      quote do
        fragment("arg_max(?, ?, ?)", unquote(argument), unquote(value), unquote(count))
      end
    end

    defmacro arg_min(argument, value) do
      quote do
        fragment("arg_min(?, ?)", unquote(argument), unquote(value))
      end
    end

    defmacro arg_min(argument, value, count) do
      quote do
        fragment("arg_min(?, ?, ?)", unquote(argument), unquote(value), unquote(count))
      end
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

    defmacro corr(left, right) do
      quote do
        fragment("corr(?, ?)", unquote(left), unquote(right))
      end
    end

    defmacro stddev(expression) do
      quote do
        fragment("stddev(?)", unquote(expression))
      end
    end

    defmacro variance(expression) do
      quote do
        fragment("variance(?)", unquote(expression))
      end
    end

    defmacro mode(expression) do
      quote do
        fragment("mode(?)", unquote(expression))
      end
    end

    defmacro weighted_avg(expression, weight) do
      quote do
        fragment("weighted_avg(?, ?)", unquote(expression), unquote(weight))
      end
    end

    defmacro skewness(expression) do
      quote do
        fragment("skewness(?)", unquote(expression))
      end
    end

    defmacro kurtosis(expression) do
      quote do
        fragment("kurtosis(?)", unquote(expression))
      end
    end

    defmacro sem(expression) do
      quote do
        fragment("sem(?)", unquote(expression))
      end
    end

    defmacro geometric_mean(expression) do
      quote do
        fragment("geometric_mean(?)", unquote(expression))
      end
    end

    defmacro covar_pop(left, right) do
      quote do
        fragment("covar_pop(?, ?)", unquote(left), unquote(right))
      end
    end

    defmacro covar_samp(left, right) do
      quote do
        fragment("covar_samp(?, ?)", unquote(left), unquote(right))
      end
    end

    defmacro regr_slope(dependent, independent) do
      quote do
        fragment("regr_slope(?, ?)", unquote(dependent), unquote(independent))
      end
    end

    defmacro regr_intercept(dependent, independent) do
      quote do
        fragment("regr_intercept(?, ?)", unquote(dependent), unquote(independent))
      end
    end

    defmacro entropy(expression) do
      quote do
        fragment("entropy(?)", unquote(expression))
      end
    end

    defmacro mad(expression) do
      quote do
        fragment("mad(?)", unquote(expression))
      end
    end

    defmacro histogram(expression) do
      quote do
        fragment("histogram(?)", unquote(expression))
      end
    end

    defmacro histogram_exact(expression, elements) do
      quote do
        fragment("histogram_exact(?, ?)", unquote(expression), unquote(elements))
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
