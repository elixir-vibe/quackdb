defmodule QuackDB.Stress do
  @table "quackdb_stress_source"
  @append_rows_table "quackdb_stress_append_rows"
  @append_columns_table "quackdb_stress_append_columns"

  def main do
    Process.flag(:trap_exit, true)
    config = config()
    {connection, cleanup, server} = connect(config)
    config = Map.put(config, :server_pid, server.pid)

    try do
      IO.puts("# QuackDB stress run")
      IO.puts("started_at=#{DateTime.utc_now() |> DateTime.to_iso8601()}")
      IO.puts("server=#{server.uri}")
      IO.puts("#{config_line(config)}\n")

      setup_source!(connection, config.rows)

      results = [
        small_query_latency(connection, config),
        concurrent_aggregate_latency(connection, config),
        materialized_result(connection, config),
        streamed_rows(connection, config),
        columnar_batches(connection, config),
        wide_nested_materialized(connection, config),
        wide_nested_columnar_batches(connection, config),
        append_rows(connection, config),
        append_columns(connection, config)
      ]

      IO.puts("\n## Summary")
      Enum.each(results, &print_summary/1)
    after
      cleanup.()
    end
  end

  defp config do
    %{
      uri: env("QUACKDB_STRESS_URI") || env("QUACKDB_TEST_URI"),
      token: env("QUACKDB_STRESS_TOKEN") || env("QUACKDB_TEST_TOKEN") || "quackdb_stress",
      port: env_int("QUACKDB_STRESS_PORT", 9495),
      rows: env_int("QUACKDB_STRESS_ROWS", 100_000),
      queries: env_int("QUACKDB_STRESS_QUERIES", 200),
      concurrency: env_int("QUACKDB_STRESS_CONCURRENCY", System.schedulers_online()),
      batch_size: env_int("QUACKDB_STRESS_BATCH_SIZE", 5_000),
      fetch_rows: env_int("QUACKDB_STRESS_FETCH_ROWS", 10_000),
      threads: env_int("QUACKDB_STRESS_THREADS", System.schedulers_online()),
      fetch_batch_chunks: env_int("QUACKDB_STRESS_FETCH_BATCH_CHUNKS", 12),
      timeout: env_int("QUACKDB_STRESS_TIMEOUT", 120_000),
      scenarios: env_list("QUACKDB_STRESS_SCENARIOS"),
      profile?: env_bool("QUACKDB_STRESS_PROFILE", false),
      profile_dir: env("QUACKDB_STRESS_PROFILE_DIR") || "tmp/stress-profiles"
    }
  end

  defp connect(%{uri: uri} = config) when is_binary(uri) and uri != "" do
    {:ok, connection} =
      QuackDB.start_link(uri: uri, token: config.token, pool_size: config.concurrency)

    {connection, fn -> stop_linked(connection) end, %{uri: uri, pid: nil}}
  end

  defp connect(config) do
    endpoint = "quack:127.0.0.1:#{config.port}"

    {:ok, server} =
      QuackDB.Server.start_link(
        endpoint: endpoint,
        token: config.token,
        settings: [threads: config.threads],
        global_settings: [quack_fetch_batch_chunks: config.fetch_batch_chunks],
        wait_timeout: config.timeout
      )

    {:ok, connection} =
      QuackDB.start_link(
        uri: QuackDB.Server.uri(server),
        token: config.token,
        pool_size: config.concurrency
      )

    cleanup = fn ->
      stop_linked(connection)
      stop_linked(server)
    end

    {connection, cleanup, %{uri: QuackDB.Server.uri(server), pid: server}}
  end

  defp setup_source!(connection, rows) do
    QuackDB.query!(connection, "DROP TABLE IF EXISTS #{@table}")

    QuackDB.query!(
      connection,
      """
      CREATE TABLE #{@table} AS
      SELECT
        i::BIGINT AS id,
        (i % 128)::INTEGER AS category,
        (i * 1.25)::DOUBLE AS amount,
        ('payload-' || i::VARCHAR) AS payload,
        [i::INTEGER, (i + 1)::INTEGER, (i + 2)::INTEGER] AS samples,
        {'id': i::BIGINT, 'category': (i % 128)::INTEGER} AS attrs
      FROM range(0, ?) AS t(i)
      """,
      [rows]
    )
  end

  defp small_query_latency(connection, config) do
    run_latency_scenario("small_query", config, fn i ->
      QuackDB.query!(connection, "SELECT ?::INTEGER + 1", [i], timeout: config.timeout)
    end)
  end

  defp concurrent_aggregate_latency(connection, config) do
    run_latency_scenario("concurrent_aggregate", config, fn i ->
      divisor = rem(i, 17) + 2

      QuackDB.query!(
        connection,
        "SELECT category, count(*), sum(amount) FROM #{@table} WHERE id % ? = 0 GROUP BY category",
        [divisor],
        timeout: config.timeout
      )
    end)
  end

  defp materialized_result(connection, config) do
    sql = narrow_result_sql()

    measure(
      "materialized_result",
      config,
      profile_sql(connection, config, "materialized_result", sql),
      fn ->
        QuackDB.query!(connection, sql, [], timeout: config.timeout).rows
        |> length()
      end
    )
  end

  defp streamed_rows(connection, config) do
    sql = narrow_result_sql()

    measure("streamed_rows", config, profile_sql(connection, config, "streamed_rows", sql), fn ->
      {:ok, count} =
        DBConnection.transaction(
          connection,
          fn tx ->
            tx
            |> QuackDB.rows(sql, [],
              max_rows: config.fetch_rows,
              timeout: config.timeout
            )
            |> Enum.reduce(0, fn _row, count -> count + 1 end)
          end,
          timeout: config.timeout
        )

      count
    end)
  end

  defp columnar_batches(connection, config) do
    sql = narrow_result_sql()

    measure(
      "columnar_batches",
      config,
      profile_sql(connection, config, "columnar_batches", sql),
      fn ->
        {:ok, count} =
          DBConnection.transaction(
            connection,
            fn tx ->
              tx
              |> QuackDB.columnar_batches(sql, [],
                max_rows: config.fetch_rows,
                timeout: config.timeout
              )
              |> Enum.reduce(0, fn batch, count -> count + batch.num_rows end)
            end,
            timeout: config.timeout
          )

        count
      end
    )
  end

  defp narrow_result_sql do
    "SELECT id, category, amount, payload FROM #{@table} ORDER BY id"
  end

  defp wide_nested_materialized(connection, config) do
    sql = wide_nested_sql()

    measure(
      "wide_nested_materialized",
      config,
      profile_sql(connection, config, "wide_nested_materialized", sql),
      fn ->
        QuackDB.query!(connection, sql, [], timeout: config.timeout).rows
        |> length()
      end
    )
  end

  defp wide_nested_columnar_batches(connection, config) do
    sql = wide_nested_sql()

    measure(
      "wide_nested_columnar_batches",
      config,
      profile_sql(connection, config, "wide_nested_columnar_batches", sql),
      fn ->
        {:ok, count} =
          DBConnection.transaction(
            connection,
            fn tx ->
              tx
              |> QuackDB.columnar_batches(sql, [],
                max_rows: config.fetch_rows,
                timeout: config.timeout
              )
              |> Enum.reduce(0, fn batch, count -> count + batch.num_rows end)
            end,
            timeout: config.timeout
          )

        count
      end
    )
  end

  defp wide_nested_sql do
    """
    SELECT
      id,
      category,
      amount,
      payload,
      payload || '-suffix' AS payload_suffix,
      repeat(payload, 2) AS payload_repeated,
      samples,
      json_object('id', id, 'category', category, 'payload', payload) AS attrs_json,
      [category, category + 1, category + 2, category + 3] AS category_window,
      CASE WHEN id % 10 = 0 THEN NULL::DOUBLE ELSE amount END AS nullable_amount,
      id % 2 = 0 AS even
    FROM #{@table}
    ORDER BY id
    """
  end

  defp append_rows(connection, config) do
    measure("append_rows", config, fn ->
      QuackDB.query!(connection, "DROP TABLE IF EXISTS #{@append_rows_table}")

      QuackDB.query!(
        connection,
        "CREATE TABLE #{@append_rows_table} (id BIGINT, category INTEGER, amount DOUBLE, payload VARCHAR)"
      )

      rows =
        Stream.map(0..(config.rows - 1), fn i ->
          [id: i, category: rem(i, 128), amount: i * 1.25, payload: "payload-#{i}"]
        end)

      QuackDB.insert_stream!(connection, @append_rows_table, rows,
        chunk_every: config.batch_size,
        columns: [id: :bigint, category: :integer, amount: :double, payload: :varchar],
        timeout: config.timeout
      ).num_rows
    end)
  end

  defp append_columns(connection, config) do
    measure("append_columns", config, fn ->
      QuackDB.query!(connection, "DROP TABLE IF EXISTS #{@append_columns_table}")

      QuackDB.query!(
        connection,
        "CREATE TABLE #{@append_columns_table} (id BIGINT, category INTEGER, amount DOUBLE, payload VARCHAR)"
      )

      0..(config.rows - 1)
      |> Stream.chunk_every(config.batch_size)
      |> Enum.reduce(0, fn indexes, total ->
        columns = [
          id: indexes,
          category: Enum.map(indexes, &rem(&1, 128)),
          amount: Enum.map(indexes, &(&1 * 1.25)),
          payload: Enum.map(indexes, &"payload-#{&1}")
        ]

        result =
          QuackDB.insert_columns!(connection, @append_columns_table, columns,
            columns: [id: :bigint, category: :integer, amount: :double, payload: :varchar],
            timeout: config.timeout
          )

        total + result.num_rows
      end)
    end)
  end

  defp run_latency_scenario(name, config, fun) do
    if skip?(config, name) do
      skipped(name)
    else
      memory_before = :erlang.memory(:total)
      rss_before = server_rss_mb(config.server_pid)
      started = System.monotonic_time(:microsecond)

      samples =
        1..config.queries
        |> Task.async_stream(
          fn i ->
            timed(fn -> fun.(i) end)
          end,
          max_concurrency: config.concurrency,
          timeout: config.timeout,
          ordered: false
        )
        |> Enum.map(fn
          {:ok, {duration, _result}} -> duration
          {:exit, reason} -> raise "#{name} task failed: #{inspect(reason)}"
        end)

      elapsed = System.monotonic_time(:microsecond) - started
      memory_after = :erlang.memory(:total)
      rss_after = server_rss_mb(config.server_pid)
      stats = latency_stats(samples) |> Map.merge(rss_stats(rss_before, rss_after))
      rate = config.queries / max(elapsed / 1_000_000, 1.0e-9)

      result(name, config.queries, elapsed, rate, memory_before, memory_after, stats)
    end
  end

  defp measure(name, config, extra_metrics \\ %{}, fun) do
    if skip?(config, name) do
      skipped(name)
    else
      memory_before = :erlang.memory(:total)
      rss_before = server_rss_mb(config.server_pid)
      {elapsed, count} = timed(fun)
      memory_after = :erlang.memory(:total)
      rss_after = server_rss_mb(config.server_pid)
      rate = count / max(elapsed / 1_000_000, 1.0e-9)

      result(
        name,
        count,
        elapsed,
        rate,
        memory_before,
        memory_after,
        rss_stats(rss_before, rss_after) |> Map.merge(extra_metrics)
      )
    end
  end

  defp profile_sql(_connection, %{profile?: false}, _name, _sql), do: %{}

  defp profile_sql(connection, %{profile?: true} = config, name, sql) do
    File.mkdir_p!(config.profile_dir)

    {elapsed, result} =
      timed(fn ->
        QuackDB.query!(connection, ["EXPLAIN ANALYZE ", sql], [], timeout: config.timeout)
      end)

    text = explain_text(result)
    path = Path.join(config.profile_dir, "#{safe_name(name)}.txt")
    File.write!(path, text)

    metrics = %{
      profile_elapsed_ms: elapsed / 1_000,
      profile_path: path
    }

    case total_time_ms(text) do
      nil -> metrics
      total_ms -> Map.put(metrics, :duckdb_total_ms, total_ms)
    end
  end

  defp explain_text(%QuackDB.Result{columns: columns, rows: rows}) do
    rows
    |> Enum.map(fn row ->
      columns
      |> Enum.zip(row)
      |> Enum.map_join("\t", fn {_column, value} -> to_string(value) end)
    end)
    |> Enum.join("\n")
  end

  defp total_time_ms(text) do
    case Regex.run(~r/Total Time:\s*([0-9.]+)\s*(s|ms)/, text) do
      [_match, value, "s"] -> String.to_float(value) * 1_000
      [_match, value, "ms"] -> String.to_float(value)
      _other -> nil
    end
  end

  defp safe_name(name) do
    String.replace(name, ~r/[^A-Za-z0-9_.-]/, "_")
  end

  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    value = fun.()
    {System.monotonic_time(:microsecond) - started, value}
  end

  defp result(name, count, elapsed, rate, memory_before, memory_after, extra) do
    metrics =
      %{
        count: count,
        elapsed_ms: elapsed / 1_000,
        rate_per_s: rate,
        memory_delta_mb: (memory_after - memory_before) / 1_048_576
      }
      |> Map.merge(extra)
      |> add_profile_overhead()

    print_metrics(name, metrics)
    %{name: name, metrics: metrics, skipped?: false}
  end

  defp skipped(name), do: %{name: name, metrics: %{}, skipped?: true}

  defp add_profile_overhead(%{elapsed_ms: elapsed_ms, duckdb_total_ms: duckdb_total_ms} = metrics) do
    Map.put(metrics, :client_overhead_ms, elapsed_ms - duckdb_total_ms)
  end

  defp add_profile_overhead(metrics), do: metrics

  defp latency_stats(samples) do
    sorted = Enum.sort(samples)

    %{
      p50_us: percentile(sorted, 0.50),
      p95_us: percentile(sorted, 0.95),
      p99_us: percentile(sorted, 0.99),
      max_us: List.last(sorted) || 0
    }
  end

  defp percentile([], _percentile), do: 0

  defp percentile(sorted, percentile) do
    index = min(length(sorted) - 1, max(0, ceil(length(sorted) * percentile) - 1))
    Enum.at(sorted, index)
  end

  defp rss_stats(nil, _rss_after), do: %{}
  defp rss_stats(_rss_before, nil), do: %{}

  defp rss_stats(rss_before, rss_after) do
    %{server_rss_mb: rss_after, server_rss_delta_mb: rss_after - rss_before}
  end

  defp server_rss_mb(nil), do: nil

  defp server_rss_mb(server_pid) do
    with os_pid when is_integer(os_pid) <- QuackDB.Server.os_pid(server_pid) do
      pids = [os_pid | descendant_pids(os_pid)] |> Enum.uniq()

      case Enum.reduce(pids, 0, &(&2 + process_rss_kb(&1))) do
        0 -> nil
        rss_kb -> rss_kb / 1024
      end
    else
      _other -> nil
    end
  end

  defp descendant_pids(os_pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(os_pid)]) do
      {"", 1} ->
        []

      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.to_integer/1)
        |> Enum.flat_map(fn pid -> [pid | descendant_pids(pid)] end)

      _other ->
        []
    end
  end

  defp process_rss_kb(os_pid) do
    with {output, 0} <- System.cmd("ps", ["-o", "rss=", "-p", Integer.to_string(os_pid)]),
         {rss_kb, _rest} <- output |> String.trim() |> Integer.parse() do
      rss_kb
    else
      _other -> 0
    end
  end

  defp print_metrics(name, metrics) do
    IO.puts("## #{name}")

    metrics
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.each(fn {key, value} ->
      IO.puts("METRIC #{name}.#{key}=#{format_metric(value)}")
    end)

    IO.puts("")
  end

  defp print_summary(%{name: name, skipped?: true}), do: IO.puts("- #{name}: skipped")

  defp print_summary(%{name: name, metrics: metrics}) do
    IO.puts(
      "- #{name}: #{format_metric(metrics.count)} rows/ops in #{format_metric(metrics.elapsed_ms)} ms (#{format_metric(metrics.rate_per_s)}/s)"
    )
  end

  defp config_line(config) do
    [
      rows: config.rows,
      queries: config.queries,
      concurrency: config.concurrency,
      batch_size: config.batch_size,
      fetch_rows: config.fetch_rows,
      threads: config.threads,
      quack_fetch_batch_chunks: config.fetch_batch_chunks,
      profile: config.profile?,
      profile_dir: config.profile_dir,
      scenarios: Enum.join(config.scenarios, ",")
    ]
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.join(" ")
  end

  defp skip?(%{scenarios: []}, _name), do: false
  defp skip?(%{scenarios: scenarios}, name), do: name not in scenarios

  defp env(name), do: System.get_env(name)

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end

  defp env_list(name) do
    case System.get_env(name) do
      nil -> []
      "" -> []
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp env_bool(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"]
    end
  end

  defp stop_linked(pid) when is_pid(pid) do
    Process.unlink(pid)
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp format_metric(value) when is_integer(value), do: Integer.to_string(value)
  defp format_metric(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_metric(value) when is_binary(value), do: value
end

QuackDB.Stress.main()
