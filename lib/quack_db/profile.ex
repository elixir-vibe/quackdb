defmodule QuackDB.Profile.Operator do
  @moduledoc """
  A DuckDB plan or profiling operator node.

  Plans from `QuackDB.Profile.explain/4` carry `name` and `extra_info`.
  Profiles from `QuackDB.Profile.analyze/4` also carry the operator `type`,
  its `timing` in seconds, and row counts.
  """

  use JSONCodec

  defstruct [
    :name,
    :type,
    :timing,
    :intermediate_rows,
    :intermediate_size_bytes,
    :rows_scanned,
    :row_groups_scanned,
    :total_row_groups_to_scan,
    extra_info: %{},
    children: []
  ]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          type: String.t() | nil,
          timing: number() | nil,
          intermediate_rows: non_neg_integer() | nil,
          intermediate_size_bytes: non_neg_integer() | nil,
          rows_scanned: non_neg_integer() | nil,
          row_groups_scanned: non_neg_integer() | nil,
          total_row_groups_to_scan: non_neg_integer() | nil,
          extra_info: %{String.t() => term()},
          children: [__MODULE__.t()]
        }
end

defmodule QuackDB.Profile.Query do
  @moduledoc "Query-level metrics of a DuckDB profile. Times are in seconds."

  use JSONCodec

  defstruct [
    :sql,
    :total_time,
    :cpu_time,
    :total_intermediate_rows,
    :total_intermediate_size_bytes,
    :total_rows_scanned,
    :total_row_groups_scanned,
    :total_row_groups_to_scan
  ]

  @type t :: %__MODULE__{
          sql: String.t() | nil,
          total_time: number() | nil,
          cpu_time: number() | nil,
          total_intermediate_rows: non_neg_integer() | nil,
          total_intermediate_size_bytes: non_neg_integer() | nil,
          total_rows_scanned: non_neg_integer() | nil,
          total_row_groups_scanned: non_neg_integer() | nil,
          total_row_groups_to_scan: non_neg_integer() | nil
        }
end

defmodule QuackDB.Profile.Planner do
  @moduledoc "Planner timings of a DuckDB profile, in seconds."

  use JSONCodec

  defstruct [:total_time, :binding_time, :column_binding, :create_plan, :resolve_types]

  @type t :: %__MODULE__{
          total_time: number() | nil,
          binding_time: number() | nil,
          column_binding: number() | nil,
          create_plan: number() | nil,
          resolve_types: number() | nil
        }
end

defmodule QuackDB.Profile.IO do
  @moduledoc "I/O metrics of a DuckDB profile."

  use JSONCodec

  defstruct [:total_bytes_read, :total_bytes_written]

  @type t :: %__MODULE__{
          total_bytes_read: non_neg_integer() | nil,
          total_bytes_written: non_neg_integer() | nil
        }
end

defmodule QuackDB.Profile.System do
  @moduledoc "Memory and scheduling metrics of a DuckDB profile."

  use JSONCodec

  defstruct [
    :blocked_thread_time,
    :peak_buffer_memory,
    :peak_streaming_buffer_size,
    :peak_temp_dir_size,
    :total_memory_allocated
  ]

  @type t :: %__MODULE__{
          blocked_thread_time: number() | nil,
          peak_buffer_memory: non_neg_integer() | nil,
          peak_streaming_buffer_size: non_neg_integer() | nil,
          peak_temp_dir_size: non_neg_integer() | nil,
          total_memory_allocated: non_neg_integer() | nil
        }
end

defmodule QuackDB.Profile do
  @moduledoc """
  DuckDB query profiling helpers.

  `analyze/4` runs `EXPLAIN (ANALYZE, FORMAT json)` and decodes DuckDB's
  profile into typed structs using JSONCodec, grouped the way DuckDB 2.0
  reports them: `query`, `parser`, `planner`, `physical_planner`, `optimizer`,
  `io`, `system`, and the `operators` tree. `explain/4` returns the plan tree
  only. DuckDB's open-ended `extra_info` maps and optimizer metric names
  retain string keys.

  Use `flatten/1`, `slowest/2`, and `report/2` when you want a profiler-style
  operator view.
  """

  use JSONCodec

  alias QuackDB.Profile.Operator

  alias QuackDB.Profile.Planner
  alias QuackDB.Profile.Query

  defstruct [
    :query,
    :parser,
    :planner,
    :physical_planner,
    :io,
    :system,
    optimizer: %{},
    operators: []
  ]

  codec(:operators, as: "operator")

  @type t :: %__MODULE__{
          query: Query.t() | nil,
          parser: Planner.t() | nil,
          planner: Planner.t() | nil,
          physical_planner: Planner.t() | nil,
          io: QuackDB.Profile.IO.t() | nil,
          system: QuackDB.Profile.System.t() | nil,
          optimizer: %{String.t() => number()},
          operators: [Operator.t()]
        }

  @typedoc "A flattened DuckDB operator row with its tree path and timing share."
  @type operator_row :: %{
          path: [non_neg_integer()],
          name: String.t() | nil,
          type: String.t() | nil,
          timing: number() | nil,
          timing_percent: float() | nil,
          cardinality: non_neg_integer() | nil,
          rows_scanned: non_neg_integer() | nil,
          size_bytes: non_neg_integer() | nil,
          extra_info: map()
        }

  @doc "Runs `EXPLAIN (FORMAT json)` and returns a decoded DuckDB plan profile."
  @spec explain(DBConnection.conn() | module(), iodata() | term(), [term()], keyword()) ::
          {:ok, t()} | {:error, Exception.t()}
  def explain(connection, statement, params \\ [], options \\ []) do
    {statement, params, options} = normalize_arguments(statement, params, options)

    with {:ok, sql, params} <- profile_statement(connection, statement, params, analyze: false),
         {:ok, result} <- QuackDB.query(connection, sql, params, options),
         {:ok, profile} <- decode_result(result) do
      build_profile(profile)
    end
  end

  @doc "Runs `EXPLAIN (FORMAT json)` and returns a decoded DuckDB plan profile, raising on errors."
  @spec explain!(DBConnection.conn() | module(), iodata() | term(), [term()], keyword()) :: t()
  def explain!(connection, statement, params \\ [], options \\ []) do
    case explain(connection, statement, params, options) do
      {:ok, profile} -> profile
      {:error, error} -> raise error
    end
  end

  @doc "Runs `EXPLAIN (ANALYZE, FORMAT json)` and returns a decoded DuckDB query profile."
  @spec analyze(DBConnection.conn() | module(), iodata() | term(), [term()], keyword()) ::
          {:ok, t()} | {:error, Exception.t()}
  def analyze(connection, statement, params \\ [], options \\ []) do
    {statement, params, options} = normalize_arguments(statement, params, options)

    with {:ok, sql, params} <- profile_statement(connection, statement, params, analyze: true),
         {:ok, result} <- QuackDB.query(connection, sql, params, options),
         {:ok, profile} <- decode_result(result) do
      build_profile(profile)
    end
  end

  @doc "Runs `EXPLAIN (ANALYZE, FORMAT json)` and returns a decoded DuckDB query profile, raising on errors."
  @spec analyze!(DBConnection.conn() | module(), iodata() | term(), [term()], keyword()) :: t()
  def analyze!(connection, statement, params \\ [], options \\ []) do
    case analyze(connection, statement, params, options) do
      {:ok, profile} -> profile
      {:error, error} -> raise error
    end
  end

  @doc "Converts DuckDB's profile tree into profiler-style operator rows."
  @spec flatten(t()) :: [operator_row()]
  def flatten(%__MODULE__{} = profile) do
    total = timing_total(profile)

    profile.operators
    |> Enum.with_index()
    |> Enum.flat_map(fn {operator, index} -> flatten_operator(operator, [index], total) end)
  end

  @doc "Returns the slowest operators by `timing`."
  @spec slowest(t(), pos_integer()) :: [operator_row()]
  def slowest(%__MODULE__{} = profile, limit \\ 10) when is_integer(limit) and limit > 0 do
    profile
    |> flatten()
    |> Enum.sort_by(&(&1.timing || 0), :desc)
    |> Enum.take(limit)
  end

  @doc "Formats a compact text report for humans."
  @spec report(t(), keyword()) :: String.t()
  def report(%__MODULE__{} = profile, options \\ []) do
    limit = Keyword.get(options, :limit, 10)
    rows = slowest(profile, limit)

    [
      "DuckDB query profile\n\n",
      metric_line("Total time", seconds(query_metric(profile, :total_time))),
      metric_line("CPU time", seconds(query_metric(profile, :cpu_time))),
      metric_line("Rows scanned", integer(query_metric(profile, :total_rows_scanned))),
      metric_line("Peak memory", bytes(profile.system && profile.system.peak_buffer_memory)),
      "\n",
      "% time   time      rows      scanned   operator\n",
      Enum.map(rows, &operator_line/1)
    ]
    |> IO.iodata_to_binary()
  end

  defp build_profile(decoded) do
    case from_map(profile_map(decoded)) do
      {:ok, profile} ->
        {:ok, profile}

      {:error, error} ->
        {:error,
         QuackDB.Error.new(
           :invalid_profile,
           "could not decode DuckDB profile: #{Exception.message(error)}",
           source: :client
         )}
    end
  end

  defp normalize_arguments(statement, params, []) when is_list(params) do
    if Keyword.keyword?(params) do
      {statement, [], params}
    else
      {statement, params, []}
    end
  end

  defp normalize_arguments(statement, params, options), do: {statement, params, options}

  defp profile_statement(connection, statement, params, options) do
    case ecto_query_statement(connection, statement) do
      {:ok, sql, ecto_params} ->
        {:ok, QuackDB.SQL.explain(sql, Keyword.put(options, :format, :json)), ecto_params}

      :error ->
        {:ok, QuackDB.SQL.explain(statement, Keyword.put(options, :format, :json)), params}
    end
  end

  defp ecto_query_statement(repo, queryable) when is_atom(repo) and not is_binary(queryable) do
    ecto_sql = Module.concat([Ecto, Adapters, SQL])

    if Code.ensure_loaded?(ecto_sql) and function_exported?(repo, :__adapter__, 0) do
      case apply(ecto_sql, :to_sql, [:all, repo, queryable]) do
        {sql, params} -> {:ok, sql, params}
        _other -> :error
      end
    else
      :error
    end
  rescue
    _error in [ArgumentError, FunctionClauseError, RuntimeError, UndefinedFunctionError] -> :error
  end

  defp ecto_query_statement(_connection, _statement), do: :error

  defp decode_result(%QuackDB.Result{columns: columns, rows: [row | _]}) when is_list(row) do
    case explain_json_value(columns || [], row) do
      value when is_binary(value) -> decode_json(value)
      _value -> {:error, %QuackDB.Error{message: "DuckDB profile output did not include JSON"}}
    end
  end

  defp decode_result(%QuackDB.Result{}) do
    {:error, %QuackDB.Error{message: "DuckDB profile output did not include JSON"}}
  end

  defp explain_json_value(columns, row) do
    case Enum.find_index(columns, &(&1 == "explain_value")) do
      nil -> fallback_explain_value(row)
      index -> Enum.at(row, index)
    end
  end

  defp fallback_explain_value([value]), do: value
  defp fallback_explain_value([_key, value | _rest]), do: value
  defp fallback_explain_value([value | _rest]), do: value
  defp fallback_explain_value([]), do: nil

  defp decode_json(json) do
    case JSON.decode(json) do
      {:ok, profile} when is_map(profile) or is_list(profile) ->
        {:ok, profile}

      {:ok, other} ->
        {:error,
         %QuackDB.Error{message: "expected DuckDB profile JSON object, got: #{inspect(other)}"}}

      {:error, error} ->
        {:error,
         %QuackDB.Error{message: "could not decode DuckDB profile JSON: #{inspect(error)}"}}
    end
  end

  # Plain EXPLAIN returns the bare plan nodes; ANALYZE returns the grouped profile.
  defp profile_map(plan) when is_list(plan), do: %{"operator" => plan}
  defp profile_map(profile), do: profile

  defp timing_total(%__MODULE__{query: %Query{cpu_time: value}})
       when is_number(value) and value > 0,
       do: value

  defp timing_total(%__MODULE__{} = profile) do
    total = Enum.reduce(profile.operators, 0, &(&2 + total_operator_timing(&1)))
    if total > 0, do: total, else: nil
  end

  defp total_operator_timing(%Operator{} = operator) do
    (operator.timing || 0) + Enum.reduce(operator.children, 0, &(&2 + total_operator_timing(&1)))
  end

  defp flatten_operator(%Operator{} = operator, path, total) do
    row = %{
      path: Enum.reverse(path),
      name: operator.name || operator.type,
      type: operator.type,
      timing: operator.timing,
      timing_percent: timing_percent(operator.timing, total),
      cardinality: operator.intermediate_rows,
      rows_scanned: operator.rows_scanned,
      size_bytes: operator.intermediate_size_bytes,
      extra_info: operator.extra_info || %{}
    }

    child_rows =
      operator.children
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, index} -> flatten_operator(child, [index | path], total) end)

    [row | child_rows]
  end

  defp timing_percent(timing, total) when is_number(timing) and is_number(total) and total > 0 do
    Float.round(timing / total * 100, 1)
  end

  defp timing_percent(_timing, _total), do: nil

  defp query_metric(%__MODULE__{query: %Query{} = query}, key), do: Map.fetch!(query, key)
  defp query_metric(%__MODULE__{}, _key), do: nil

  defp metric_line(label, value), do: [String.pad_trailing(label <> ":", 16), value, "\n"]

  defp operator_line(row) do
    [
      String.pad_leading(format_percent(row.timing_percent), 6),
      "   ",
      String.pad_leading(seconds(row.timing), 8),
      "  ",
      String.pad_leading(integer(row.cardinality), 8),
      "  ",
      String.pad_leading(integer(row.rows_scanned), 8),
      "   ",
      row.name || row.type || "?",
      "\n"
    ]
  end

  defp format_percent(nil), do: "-"
  defp format_percent(value), do: :io_lib.format("~.1f", [value]) |> IO.iodata_to_binary()

  defp seconds(nil), do: "-"

  defp seconds(value) when is_number(value) do
    :io_lib.format("~.3fms", [value * 1000]) |> IO.iodata_to_binary()
  end

  defp integer(nil), do: "-"

  defp integer(value) when is_integer(value),
    do: value |> Integer.to_string() |> add_integer_separators()

  defp integer(value), do: to_string(value)

  defp bytes(nil), do: "-"
  defp bytes(value) when is_integer(value) and value < 1024, do: "#{value} B"

  defp bytes(value) when is_integer(value) and value < 1_048_576 do
    :io_lib.format("~.1f KB", [value / 1024]) |> IO.iodata_to_binary()
  end

  defp bytes(value) when is_integer(value) do
    :io_lib.format("~.1f MB", [value / 1_048_576]) |> IO.iodata_to_binary()
  end

  defp add_integer_separators(value) do
    value
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
