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
            scores: duckdb_list(event.score)
          }
        )

    Helpers only build expressions. DuckDB clauses that are not representable in
    Ecto's AST, such as `PIVOT`, `UNPIVOT`, `QUALIFY`, `GROUPING SETS`, and
    `USING SAMPLE`, should still be sent as raw SQL.
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

    defmacro duckdb_list(expression) do
      quote do
        fragment("list(?)", unquote(expression))
      end
    end

    defmacro string_agg(expression, separator) do
      quote do
        fragment("string_agg(?, ?)", unquote(expression), unquote(separator))
      end
    end

    defmacro arg_max(argument, value) do
      quote do
        fragment("arg_max(?, ?)", unquote(argument), unquote(value))
      end
    end

    defmacro arg_min(argument, value) do
      quote do
        fragment("arg_min(?, ?)", unquote(argument), unquote(value))
      end
    end

    defmacro json_extract(expression, path) do
      quote do
        fragment("json_extract(?, ?)", unquote(expression), unquote(path))
      end
    end

    defmacro json_extract_string(expression, path) do
      quote do
        fragment("json_extract_string(?, ?)", unquote(expression), unquote(path))
      end
    end

    defmacro date_trunc(part, timestamp) do
      quote do
        fragment("date_trunc(?, ?)", unquote(part), unquote(timestamp))
      end
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
  end
end
