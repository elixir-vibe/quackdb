defmodule QuackDB.Profile.Operator do
  @moduledoc "A DuckDB profiling operator node."

  defstruct [
    :cpu_time,
    :cumulative_cardinality,
    :cumulative_rows_scanned,
    :extra_info,
    :operator_cardinality,
    :operator_name,
    :operator_rows_scanned,
    :operator_timing,
    :operator_type,
    :result_set_size,
    :system_peak_buffer_memory,
    :system_peak_temp_dir_size,
    children: []
  ]

  @type t :: %__MODULE__{
          operator_name: String.t() | nil,
          operator_type: String.t() | nil,
          operator_timing: number() | nil,
          cpu_time: number() | nil,
          operator_cardinality: non_neg_integer() | nil,
          operator_rows_scanned: non_neg_integer() | nil,
          cumulative_cardinality: non_neg_integer() | nil,
          cumulative_rows_scanned: non_neg_integer() | nil,
          result_set_size: non_neg_integer() | nil,
          extra_info: map(),
          children: [t()]
        }
end

defmodule QuackDB.Profile do
  @moduledoc """
  DuckDB query profiling helpers.

  `analyze/4` runs `EXPLAIN (ANALYZE, FORMAT json)` and decodes DuckDB's
  profile with Elixir's built-in `JSON.decode/3`. Known DuckDB profile keys are
  decoded with `String.to_existing_atom/1` and loaded into structs. DuckDB's
  open-ended `extra_info` maps keep their own keys.

  Use `flatten/1`, `slowest/2`, and `report/2` when you want a profiler-style
  operator view.
  """

  alias QuackDB.Profile.Operator

  defstruct [
    :all_optimizers,
    :attach_load_storage_latency,
    :attach_replay_wal_latency,
    :blocked_thread_time,
    :checkpoint_latency,
    :commit_local_storage_latency,
    :cpu_time,
    :cumulative_cardinality,
    :cumulative_optimizer_timing,
    :cumulative_rows_scanned,
    :extra_info,
    :latency,
    :physical_planner,
    :physical_planner_column_binding,
    :physical_planner_create_plan,
    :physical_planner_resolve_types,
    :planner,
    :planner_binding,
    :query_name,
    :result_set_size,
    :rows_returned,
    :system_peak_buffer_memory,
    :system_peak_temp_dir_size,
    :total_bytes_read,
    :total_bytes_written,
    :total_memory_allocated,
    :waiting_to_attach_latency,
    :wal_replay_entry_count,
    :write_to_wal_latency,
    children: [],
    optimizers: %{}
  ]

  @type t :: %__MODULE__{
          query_name: String.t() | nil,
          latency: number() | nil,
          cpu_time: number() | nil,
          rows_returned: non_neg_integer() | nil,
          result_set_size: non_neg_integer() | nil,
          cumulative_cardinality: non_neg_integer() | nil,
          cumulative_rows_scanned: non_neg_integer() | nil,
          children: [Operator.t()],
          optimizers: map()
        }

  @typedoc "A flattened DuckDB operator row with its tree path and timing share."
  @type operator_row :: %{
          path: [non_neg_integer()],
          name: String.t() | nil,
          type: String.t() | nil,
          timing: number() | nil,
          timing_percent: float() | nil,
          cpu_time: number() | nil,
          cardinality: non_neg_integer() | nil,
          rows_scanned: non_neg_integer() | nil,
          cumulative_cardinality: non_neg_integer() | nil,
          cumulative_rows_scanned: non_neg_integer() | nil,
          result_set_size: non_neg_integer() | nil,
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
      {:ok, build_profile(profile)}
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
      {:ok, build_profile(profile)}
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

    profile.children
    |> Enum.with_index()
    |> Enum.flat_map(fn {operator, index} -> flatten_operator(operator, [index], total) end)
  end

  @doc "Returns the slowest operators by `operator_timing`."
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
      metric_line("Latency", seconds(profile.latency)),
      metric_line("CPU time", seconds(profile.cpu_time)),
      metric_line("Rows scanned", integer(profile.cumulative_rows_scanned)),
      metric_line("Rows returned", integer(profile.rows_returned)),
      metric_line("Peak memory", bytes(profile.system_peak_buffer_memory)),
      "\n",
      "% time   time      rows      scanned   operator\n",
      Enum.map(rows, &operator_line/1)
    ]
    |> IO.iodata_to_binary()
  end

  defp build_profile(%{} = decoded) do
    profile_fields = Map.keys(%__MODULE__{}) -- [:__struct__, :children, :optimizers]

    decoded
    |> Map.take(profile_fields)
    |> Map.put(:children, Enum.map(Map.get(decoded, :children, []), &build_operator/1))
    |> Map.put(:optimizers, optimizer_metrics(decoded))
    |> then(&struct!(__MODULE__, &1))
  end

  defp build_operator(%{} = decoded) do
    operator_fields = Map.keys(%Operator{}) -- [:__struct__, :children]

    decoded
    |> Map.take(operator_fields)
    |> Map.put(:children, Enum.map(Map.get(decoded, :children, []), &build_operator/1))
    |> then(&struct!(Operator, &1))
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
    case JSON.decode(json, [], profile_decoders()) do
      {[profile], _acc, ""} when is_map(profile) ->
        {:ok, profile}

      {profile, _acc, ""} when is_map(profile) ->
        {:ok, profile}

      {other, _acc, ""} ->
        {:error,
         %QuackDB.Error{message: "expected DuckDB profile JSON object, got: #{inspect(other)}"}}

      {:error, error} ->
        {:error,
         %QuackDB.Error{message: "could not decode DuckDB profile JSON: #{inspect(error)}"}}
    end
  end

  defp profile_decoders do
    [
      object_push: fn key, value, acc -> [{existing_profile_key(key), value} | acc] end,
      object_finish: fn acc, old_acc -> {Map.new(acc), old_acc} end
    ]
  end

  defp existing_profile_key("optimizer_" <> _ = key), do: key

  defp existing_profile_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp optimizer_metrics(decoded) do
    decoded
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and String.starts_with?(key, "optimizer_") and is_number(value)
    end)
    |> Map.new(fn {key, value} -> {String.replace_prefix(key, "optimizer_", ""), value} end)
  end

  defp timing_total(%__MODULE__{cpu_time: value}) when is_number(value) and value > 0, do: value

  defp timing_total(%__MODULE__{} = profile) do
    total = Enum.reduce(profile.children, 0, &(&2 + total_operator_timing(&1)))
    if total > 0, do: total, else: nil
  end

  defp total_operator_timing(%Operator{} = operator) do
    (operator.operator_timing || 0) +
      Enum.reduce(operator.children, 0, &(&2 + total_operator_timing(&1)))
  end

  defp flatten_operator(%Operator{} = operator, path, total) do
    row = %{
      path: Enum.reverse(path),
      name: operator.operator_name,
      type: operator.operator_type,
      timing: operator.operator_timing,
      timing_percent: timing_percent(operator.operator_timing, total),
      cpu_time: operator.cpu_time,
      cardinality: operator.operator_cardinality,
      rows_scanned: operator.operator_rows_scanned,
      cumulative_cardinality: operator.cumulative_cardinality,
      cumulative_rows_scanned: operator.cumulative_rows_scanned,
      result_set_size: operator.result_set_size,
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
