if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Star do
    @moduledoc """
    DuckDB star and `COLUMNS(...)` expression macros for Ecto SQL generation.

    These helpers wrap `QuackDB.SQL.star/1`, `QuackDB.SQL.columns/1,2`, and
    `QuackDB.SQL.unpack_columns/1,2` in Ecto fragments.

    DuckDB star expressions can expand one Ecto expression into multiple SQL
    result columns. That is useful for SQL generation and raw `Repo.query!/2`
    execution, but it can surprise Ecto's normal result loader in `Repo.all/2`
    select lists. Prefer these macros in predicates or when you intentionally
    pass generated SQL to `Repo.query!/2`.
    """

    @doc "Builds a DuckDB star expression fragment."
    defmacro star(options \\ []) do
      fragment_sql = options |> QuackDB.SQL.star() |> IO.iodata_to_binary()

      quote do
        fragment(unquote(fragment_sql))
      end
    end

    @doc false
    def __selector_param__(selector) when is_list(selector), do: Enum.map(selector, &to_string/1)
    def __selector_param__(selector) when is_binary(selector), do: selector

    @doc "Builds a DuckDB `COLUMNS(...)` expression fragment."
    defmacro columns(selector \\ :star, options \\ [])

    defmacro columns({:^, meta, [selector]}, []) do
      pinned_selector =
        {:^, meta, [{{:., [], [__MODULE__, :__selector_param__]}, [], [selector]}]}

      quote do
        fragment("COLUMNS(?)", unquote(pinned_selector))
      end
    end

    defmacro columns({:^, _meta, [_selector]}, options) do
      raise ArgumentError,
            "dynamic COLUMNS selectors cannot be combined with star options: #{inspect(options)}"
    end

    defmacro columns(selector, options) do
      fragment_sql = selector |> QuackDB.SQL.columns(options) |> IO.iodata_to_binary()

      quote do
        fragment(unquote(fragment_sql))
      end
    end

    @doc "Builds a DuckDB `*COLUMNS(...)` unpacked columns expression fragment."
    defmacro unpack_columns(selector \\ :star, options \\ [])

    defmacro unpack_columns({:^, meta, [selector]}, []) do
      pinned_selector =
        {:^, meta, [{{:., [], [__MODULE__, :__selector_param__]}, [], [selector]}]}

      quote do
        fragment("*COLUMNS(?)", unquote(pinned_selector))
      end
    end

    defmacro unpack_columns({:^, _meta, [_selector]}, options) do
      raise ArgumentError,
            "dynamic *COLUMNS selectors cannot be combined with star options: #{inspect(options)}"
    end

    defmacro unpack_columns(selector, options) do
      fragment_sql = selector |> QuackDB.SQL.unpack_columns(options) |> IO.iodata_to_binary()

      quote do
        fragment(unquote(fragment_sql))
      end
    end
  end
end
