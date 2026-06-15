alias QuackDB.Type

{opts, _argv, invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      rows: :integer,
      chunk: :integer,
      ast_bytes: :integer,
      terms: :integer,
      sub_hashes: :integer,
      database: :string,
      output: :string,
      keep_database: :boolean,
      port: :integer,
      connections: :integer
    ]
  )

if invalid != [] do
  raise ArgumentError, "invalid options: #{inspect(invalid)}"
end

rows = Keyword.get(opts, :rows, 100_000)
chunk = Keyword.get(opts, :chunk, 10_000)
ast_bytes = Keyword.get(opts, :ast_bytes, 700)
terms_per_row = Keyword.get(opts, :terms, 43)
sub_hashes_per_row = Keyword.get(opts, :sub_hashes, 10)
keep_database? = Keyword.get(opts, :keep_database, false)
output = Keyword.get(opts, :output)
connections = Keyword.get(opts, :connections, 1)

if rows < 0, do: raise(ArgumentError, "--rows must be non-negative")
if chunk <= 0, do: raise(ArgumentError, "--chunk must be positive")
if ast_bytes < 8, do: raise(ArgumentError, "--ast-bytes must be at least 8")
if terms_per_row < 0, do: raise(ArgumentError, "--terms must be non-negative")
if sub_hashes_per_row < 0, do: raise(ArgumentError, "--sub-hashes must be non-negative")
if connections <= 0, do: raise(ArgumentError, "--connections must be positive")

Application.ensure_all_started(:quackdb)

database =
  Keyword.get_lazy(opts, :database, fn ->
    Path.join(
      System.tmp_dir!(),
      "quackdb-wide-append-#{System.unique_integer([:positive])}.duckdb"
    )
  end)

File.rm(database)
File.rm(database <> ".wal")

port = Keyword.get_lazy(opts, :port, fn -> 40_000 + :rand.uniform(20_000) end)
token = "wide_append"
endpoint = "quack:127.0.0.1:#{port}"

{:ok, server} =
  QuackDB.Server.start_link(
    duckdb: :managed,
    database: database,
    endpoint: endpoint,
    token: token
  )

conns =
  for _ <- 1..connections do
    {:ok, conn} =
      QuackDB.start_link(
        uri: QuackDB.Server.uri(server),
        token: token,
        receive_timeout: :infinity
      )

    conn
  end

columns = [
  package_id: :integer,
  package_version_id: :integer,
  file_id: :integer,
  content_hash: :blob,
  ast: :blob,
  kind: :varchar,
  module: :varchar,
  name: :varchar,
  arity: :integer,
  line: :integer,
  end_line: :integer,
  mass: :integer,
  exact_hash: :blob,
  terms: {:list, :integer},
  sub_hashes: {:list, :integer},
  inserted_at: :timestamp,
  updated_at: :timestamp
]

create_table_sql = fn table ->
  [
    "CREATE TABLE ",
    Type.quote_identifier(table),
    " (",
    columns
    |> Enum.map(fn {name, type} -> [Type.quote_identifier(name), " ", Type.to_sql(type)] end)
    |> Enum.intersperse(", "),
    ")"
  ]
end

for index <- 1..connections do
  QuackDB.query!(hd(conns), create_table_sql.("wide_fragments_#{index}"), [], timeout: :infinity)
end

{:ok, telemetry_agent} = Agent.start_link(fn -> [] end)
handler_id = "wide-append-#{System.unique_integer([:positive])}"

:telemetry.attach(
  handler_id,
  [:quackdb, :append, :stop],
  fn _event, measurements, metadata, agent ->
    Agent.update(agent, fn events -> [{measurements, metadata} | events] end)
  end,
  telemetry_agent
)

base_ast_tail = :binary.copy(<<1, 2, 3, 4, 5, 6, 7, 8>>, div(ast_bytes - 8 + 7, 8))
base_ast_tail = binary_part(base_ast_tail, 0, ast_bytes - 8)
now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

make_binary32 = fn i -> <<i::unsigned-big-256>> end
make_ast = fn i -> <<i::unsigned-big-64, base_ast_tail::binary>> end

make_terms = fn i ->
  if terms_per_row == 0, do: [], else: Enum.map(1..terms_per_row//1, &(&1 + rem(i, 4096)))
end

make_sub_hashes = fn i ->
  if sub_hashes_per_row == 0, do: [], else: Enum.map(1..sub_hashes_per_row//1, &(&1 * 131 + i))
end

make_batch = fn first, count ->
  last = first + count - 1
  range = first..last//1

  [
    package_id: Enum.map(range, &(1 + rem(&1, 500))),
    package_version_id: Enum.map(range, &(1 + rem(&1, 500))),
    file_id: Enum.map(range, &(1 + rem(&1, 10_000))),
    content_hash: Enum.map(range, make_binary32),
    ast: Enum.map(range, make_ast),
    kind: Enum.map(range, fn i -> if rem(i, 3) == 0, do: "function", else: "call" end),
    module: Enum.map(range, &("Bench.Module" <> Integer.to_string(rem(&1, 10_000)))),
    name: Enum.map(range, &("name_" <> Integer.to_string(rem(&1, 2_000)))),
    arity: Enum.map(range, &rem(&1, 5)),
    line: Enum.map(range, &(1 + rem(&1, 1_000))),
    end_line: Enum.map(range, &(2 + rem(&1, 1_000))),
    mass: Enum.map(range, &(1 + rem(&1, 20))),
    exact_hash: Enum.map(range, fn i -> make_binary32.(i + rows + 1) end),
    terms: Enum.map(range, make_terms),
    sub_hashes: Enum.map(range, make_sub_hashes),
    inserted_at: List.duplicate(now, count),
    updated_at: List.duplicate(now, count)
  ]
end

started_at = System.monotonic_time()

append_partition = fn {conn, index, first, partition_rows} ->
  table = "wide_fragments_#{index}"

  if partition_rows == 0 do
    []
  else
    first..(first + partition_rows - 1)//chunk
    |> Enum.map(fn batch_first ->
      count = min(chunk, first + partition_rows - batch_first)
      batch = make_batch.(batch_first, count)

      {duration, result} =
        :timer.tc(fn ->
          QuackDB.insert_columns!(conn, table, batch,
            columns: columns,
            timeout: :infinity,
            client_query_id: "wide-append-#{index}-#{batch_first}"
          )
        end)

      %{
        table: table,
        first: batch_first,
        rows: count,
        duration_us: duration,
        result_rows: result.num_rows
      }
    end)
  end
end

partitions =
  Enum.map(1..connections, fn index ->
    base = div(rows, connections)
    extra = if index <= rem(rows, connections), do: 1, else: 0
    partition_rows = base + extra
    first = 1 + base * (index - 1) + min(index - 1, rem(rows, connections))
    {Enum.at(conns, index - 1), index, first, partition_rows}
  end)

append_results =
  partitions
  |> Task.async_stream(append_partition, timeout: :infinity, max_concurrency: connections)
  |> Enum.flat_map(fn {:ok, results} -> results end)

elapsed_native = System.monotonic_time() - started_at

count =
  1..connections
  |> Enum.map(fn index ->
    %{rows: [[count]]} =
      QuackDB.query!(hd(conns), "SELECT count(*) FROM wide_fragments_#{index}", [],
        timeout: :infinity
      )

    count
  end)
  |> Enum.sum()

telemetry = Agent.get(telemetry_agent, &Enum.reverse/1)
:telemetry.detach(handler_id)

sum_metadata = fn key ->
  Enum.reduce(telemetry, 0, fn {_measurements, metadata}, acc ->
    acc + Map.get(metadata, key, 0)
  end)
end

summary = %{
  database: database,
  rows: rows,
  chunk: chunk,
  ast_bytes: ast_bytes,
  terms_per_row: terms_per_row,
  sub_hashes_per_row: sub_hashes_per_row,
  connections: connections,
  table_rows: count,
  batches: length(append_results),
  elapsed_us: System.convert_time_unit(elapsed_native, :native, :microsecond),
  batch_duration_us: Enum.sum(Enum.map(append_results, & &1.duration_us)),
  telemetry: %{
    append_duration_us:
      sum_metadata.(:append_duration) |> System.convert_time_unit(:native, :microsecond),
    encode_duration_us:
      sum_metadata.(:encode_duration) |> System.convert_time_unit(:native, :microsecond),
    transport_duration_us:
      sum_metadata.(:transport_duration) |> System.convert_time_unit(:native, :microsecond),
    decode_duration_us:
      sum_metadata.(:decode_duration) |> System.convert_time_unit(:native, :microsecond),
    request_bytes: sum_metadata.(:request_bytes),
    response_bytes: sum_metadata.(:response_bytes)
  },
  per_batch_us: append_results
}

encoded = Jason.encode!(summary, pretty: true)
IO.puts(encoded)

if output do
  File.mkdir_p!(Path.dirname(output))
  File.write!(output, encoded)
end

unless keep_database? do
  File.rm(database)
  File.rm(database <> ".wal")
end
