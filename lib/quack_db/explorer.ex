if Code.ensure_loaded?(Explorer.DataFrame) do
  defmodule QuackDB.Explorer do
    @moduledoc """
    Optional Explorer integration for QuackDB results.

    This module requires the optional `:explorer` dependency at runtime. It materializes
    QuackDB query results in Elixir and then builds an `Explorer.DataFrame`.
    It is not a zero-copy Arrow IPC path.
    """

    alias Explorer.DataFrame
    alias QuackDB.Columns
    alias QuackDB.Result

    @type dataframe_option :: {:dataframe, Keyword.t()} | {:query, Keyword.t()}
    @type insert_dataframe_option ::
            {:columns, list()} | {:batch_size, pos_integer()} | {:schema, String.t()}

    @doc """
    Appends an `Explorer.DataFrame` to a DuckDB table through Quack's native append protocol.

    This uses `QuackDB.insert_columns/4` to preserve Explorer's columnar shape and
    avoid row materialization. Pass `:columns` to override inferred DuckDB types.
    `:batch_size` and `:schema` are forwarded to `QuackDB.insert_columns/4`.
    """
    @spec insert_dataframe(DBConnection.conn(), String.t() | atom(), DataFrame.t(), Keyword.t()) ::
            {:ok, QuackDB.Result.t()} | {:error, Exception.t()}
    def insert_dataframe(connection, table, dataframe, options \\ []) do
      with :ok <- ensure_explorer() do
        columns = dataframe_columns(dataframe)
        append_options = dataframe_append_options(dataframe, options)

        QuackDB.insert_columns(connection, table, columns, append_options)
      end
    rescue
      error -> {:error, error}
    end

    @doc """
    Appends an `Explorer.DataFrame` to a DuckDB table, raising on error.
    """
    @spec insert_dataframe!(DBConnection.conn(), String.t() | atom(), DataFrame.t(), Keyword.t()) ::
            QuackDB.Result.t()
    def insert_dataframe!(connection, table, dataframe, options \\ []) do
      case insert_dataframe(connection, table, dataframe, options) do
        {:ok, result} -> result
        {:error, error} -> raise error
      end
    end

    @doc """
    Converts a `QuackDB.Columns` struct into an `Explorer.DataFrame`.

    Options are passed to `Explorer.DataFrame.new/2`.
    """
    @spec from_columns(Columns.t(), Keyword.t()) :: {:ok, DataFrame.t()} | {:error, Exception.t()}
    def from_columns(%Columns{} = columns, options \\ []) do
      with :ok <- ensure_explorer() do
        dataframe_options = Keyword.get(options, :dataframe, options)

        columns
        |> dataframe_input()
        |> then(&DataFrame.new(&1, dataframe_options))
        |> ok()
      end
    rescue
      error -> {:error, error}
    end

    @doc """
    Converts a `QuackDB.Columns` struct into an `Explorer.DataFrame`, raising on error.
    """
    @spec from_columns!(Columns.t(), Keyword.t()) :: DataFrame.t()
    def from_columns!(%Columns{} = columns, options \\ []) do
      case from_columns(columns, options) do
        {:ok, dataframe} -> dataframe
        {:error, error} -> raise error
      end
    end

    @doc """
    Converts a `QuackDB.Result` into an `Explorer.DataFrame`.
    """
    @spec from_result(Result.t(), Keyword.t()) :: {:ok, DataFrame.t()} | {:error, Exception.t()}
    def from_result(%Result{} = result, options \\ []) do
      result
      |> Result.to_columnar()
      |> from_columns(options)
    end

    @doc """
    Converts a `QuackDB.Result` into an `Explorer.DataFrame`, raising on error.
    """
    @spec from_result!(Result.t(), Keyword.t()) :: DataFrame.t()
    def from_result!(%Result{} = result, options \\ []) do
      case from_result(result, options) do
        {:ok, dataframe} -> dataframe
        {:error, error} -> raise error
      end
    end

    @doc """
    Runs a QuackDB query and returns an `Explorer.DataFrame`.

    The query can be raw SQL iodata or an Ecto query. Use `:query` to pass
    QuackDB query options and `:dataframe` to pass options to
    `Explorer.DataFrame.new/2`.
    """
    @spec dataframe(DBConnection.conn(), iodata() | term(), [term()] | Keyword.t(), [
            dataframe_option()
          ]) ::
            {:ok, DataFrame.t()} | {:error, Exception.t()}
    def dataframe(connection, statement_or_query, params \\ [], options \\ [])

    def dataframe(connection, query, options, [])
        when is_map(query) and :erlang.is_map_key(:__struct__, query) and
               :erlang.map_get(:__struct__, query) == Ecto.Query and is_list(options) do
      {statement, params} = ecto_statement_and_params(query)
      dataframe(connection, statement, params, options)
    end

    def dataframe(connection, statement, params, options) do
      query_options = Keyword.get(options, :query, [])
      dataframe_options = Keyword.get(options, :dataframe, [])

      case QuackDB.columnar(connection, statement, params, query_options) do
        {:ok, columns} -> from_columns(columns, dataframe_options)
        {:error, _error} = error -> error
      end
    end

    @doc """
    Runs a QuackDB query and returns an `Explorer.DataFrame`, raising on error.
    """
    @spec dataframe!(DBConnection.conn(), iodata(), [term()], [dataframe_option()]) ::
            DataFrame.t()
    def dataframe!(connection, statement, params \\ [], options \\ []) do
      case dataframe(connection, statement, params, options) do
        {:ok, dataframe} -> dataframe
        {:error, error} -> raise error
      end
    end

    defp ecto_statement_and_params(query) do
      statement =
        Ecto.Adapters.QuackDB.Connection
        |> apply(:all, [query])
        |> IO.iodata_to_binary()

      {statement, ecto_params(query)}
    end

    defp ecto_params(query) do
      query
      |> query_param_sources()
      |> Enum.flat_map(&params_from/1)
    end

    defp query_param_sources(query) do
      [
        query.select,
        query.from,
        query.distinct,
        query.limit,
        query.offset,
        query.joins,
        Enum.map(query.joins, & &1.on),
        query.wheres,
        query.group_bys,
        query.havings,
        query.order_bys,
        cte_queries(query.with_ctes)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
    end

    defp cte_queries(nil), do: []

    defp cte_queries(%{__struct__: Ecto.Query.WithExpr, queries: queries}) do
      Enum.map(queries, fn {_name, _operation, query} -> query_param_sources(query) end)
    end

    defp params_from(%{params: params}) when is_list(params) do
      Enum.map(params, fn
        {value, _type} -> value
        value -> value
      end)
    end

    defp params_from(_expr), do: []

    defp dataframe_columns(dataframe) do
      values = DataFrame.to_columns(dataframe)
      Enum.map(DataFrame.names(dataframe), fn name -> {name, Map.fetch!(values, name)} end)
    end

    defp dataframe_append_options(dataframe, options) do
      options
      |> Keyword.take([:batch_size, :schema])
      |> Keyword.put(:columns, Keyword.get(options, :columns, dataframe_column_types(dataframe)))
    end

    defp dataframe_column_types(dataframe) do
      dtypes = DataFrame.dtypes(dataframe)

      Enum.map(DataFrame.names(dataframe), fn name ->
        {name, dataframe_column_type(Map.fetch!(dtypes, name))}
      end)
    end

    defp dataframe_column_type(:boolean), do: :boolean
    defp dataframe_column_type(:string), do: :varchar
    defp dataframe_column_type(:date), do: :date
    defp dataframe_column_type({:s, 8}), do: :tinyint
    defp dataframe_column_type({:s, 16}), do: :smallint
    defp dataframe_column_type({:s, 32}), do: :integer
    defp dataframe_column_type({:s, 64}), do: :bigint
    defp dataframe_column_type({:u, 8}), do: :utinyint
    defp dataframe_column_type({:u, 16}), do: :usmallint
    defp dataframe_column_type({:u, 32}), do: :uinteger
    defp dataframe_column_type({:u, 64}), do: :ubigint
    defp dataframe_column_type({:f, 32}), do: :float
    defp dataframe_column_type({:f, 64}), do: :double
    defp dataframe_column_type({:naive_datetime, _precision}), do: {:timestamp, :timestamp}

    defp dataframe_column_type({:datetime, _precision, _time_zone}),
      do: {:timestamp, :timestamptz}

    defp dataframe_column_type({:list, dtype}), do: {:list, dataframe_column_type(dtype)}

    defp dataframe_column_type(dtype) do
      raise QuackDB.Error.new(
              :unsupported_explorer_dtype,
              "unsupported Explorer dtype #{inspect(dtype)}",
              source: :client
            )
    end

    defp ensure_explorer do
      if Code.ensure_loaded?(DataFrame) do
        :ok
      else
        {:error,
         QuackDB.Error.new(
           :missing_optional_dependency,
           "QuackDB.Explorer requires the optional :explorer dependency",
           source: :client
         )}
      end
    end

    defp dataframe_input(%Columns{names: names, columns: columns}) do
      Map.new(names, fn name -> {name, Map.fetch!(columns, name)} end)
    end

    defp ok(dataframe), do: {:ok, dataframe}
  end
end
