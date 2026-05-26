if Code.ensure_loaded?(Ecto.Schema) do
  defmodule QuackDB.Ecto.Series.DateValue do
    @moduledoc false

    use Ecto.Schema

    @primary_key false
    schema "series" do
      field(:value, :date)
    end
  end

  defmodule QuackDB.Ecto.Series.TimestampValue do
    @moduledoc false

    use Ecto.Schema

    @primary_key false
    schema "series" do
      field(:value, :naive_datetime)
    end
  end
end

if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Series do
    @moduledoc """
    Ecto source helpers for DuckDB `generate_series` table functions.

    These helpers accept Elixir ranges and return schema-backed Ecto sources with
    a stable `value` field instead of exposing DuckDB's `generate_series` column
    name in application queries.
    """

    alias QuackDB.SQL

    @doc "Builds a typed `generate_series` Ecto source from a date range."
    @spec series(Date.Range.t(), keyword()) :: {String.t(), QuackDB.Ecto.Series.DateValue}
    defmacro series(range, options \\ []) do
      quote bind_quoted: [range: range, options: options] do
        QuackDB.Ecto.Series.series_source(range, options)
      end
    end

    @doc "Builds a typed `generate_series` Ecto source from date or timestamp endpoints."
    @spec series(Date.t() | NaiveDateTime.t(), Date.t() | NaiveDateTime.t(), keyword()) ::
            {String.t(), QuackDB.Ecto.Series.DateValue | QuackDB.Ecto.Series.TimestampValue}
    defmacro series(first, last, options) do
      quote bind_quoted: [first: first, last: last, options: options] do
        QuackDB.Ecto.Series.series_source(first, last, options)
      end
    end

    def series_source(%Date.Range{} = range, options) when is_list(options) do
      step = Keyword.get_lazy(options, :step, fn -> Duration.new!(day: range.step) end)
      series_source(range.first, range.last, Keyword.put(options, :step, step))
    end

    def series_source(range, _options) do
      raise ArgumentError, "expected a Date.Range, got: #{inspect(range)}"
    end

    def series_source(%Date{} = first, %Date{} = last, options) when is_list(options) do
      step = Keyword.get_lazy(options, :step, fn -> Duration.new!(day: 1) end)

      {generate_series(first, last, step, "CAST(generate_series AS DATE)"),
       QuackDB.Ecto.Series.DateValue}
    end

    def series_source(%NaiveDateTime{} = first, %NaiveDateTime{} = last, options)
        when is_list(options) do
      step = Keyword.get_lazy(options, :step, fn -> Duration.new!(hour: 1) end)
      {generate_series(first, last, step, "generate_series"), QuackDB.Ecto.Series.TimestampValue}
    end

    def series_source(first, last, _options) do
      raise ArgumentError,
            "expected Date or NaiveDateTime endpoints, got: #{inspect(first)} and #{inspect(last)}"
    end

    defp generate_series(first, last, %Duration{} = step, value_expression) do
      [
        "(SELECT ",
        value_expression,
        " AS value FROM generate_series(",
        SQL.literal!(first),
        ", ",
        SQL.literal!(last),
        ", ",
        SQL.literal!(step),
        "))"
      ]
      |> IO.iodata_to_binary()
    end

    defp generate_series(_first, _last, step, _value_expression) do
      raise ArgumentError, "expected :step to be a Duration, got: #{inspect(step)}"
    end
  end
end
