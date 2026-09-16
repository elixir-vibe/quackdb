if Code.ensure_loaded?(Ecto.ParameterizedType) do
  defmodule QuackDB.Ecto.Decimal do
    @moduledoc """
    An Ecto decimal type retaining DuckDB cast precision and scale.

        alias QuackDB.Ecto.Decimal, as: DuckDecimal

        decimal = Ecto.ParameterizedType.init(DuckDecimal, precision: 18, scale: 4)
        estimate = dynamic([t], type(t.fields[^field], ^decimal))
        predicate = dynamic([t], ^estimate > ^minimum)
        from t in "tasks", where: ^predicate

    Import `Ecto.Query` or use `QuackDB.Ecto` for these query macros. Unlike bare
    `:decimal` (DuckDB `DECIMAL(18,3)`), this type emits the specified precision
    and scale in SQL casts. Values use ordinary Ecto decimal casting/loading;
    DuckDB enforces the SQL precision and scale, including rounding and overflow.
    """
    use Ecto.ParameterizedType

    @impl true
    def init(options) do
      precision = Keyword.fetch!(options, :precision)
      scale = Keyword.fetch!(options, :scale)

      unless is_integer(precision) and precision in 1..38 and
               is_integer(scale) and scale >= 0 and scale <= precision do
        raise ArgumentError, "expected decimal precision in 1..38 and scale in 0..precision"
      end

      %{precision: precision, scale: scale}
    end

    @impl true
    def type(_params), do: :decimal

    @impl true
    def cast(value, _params), do: Ecto.Type.cast(:decimal, value)

    @impl true
    def load(value, loader, _params), do: loader.(:decimal, value)

    @impl true
    def dump(value, dumper, _params), do: dumper.(:decimal, value)
  end
end
