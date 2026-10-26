# Regenerates the DuckDB 2.0 wire fixtures in this directory from a real server.
#
#     QUACKDB_TEST_DUCKDB=/path/to/duckdb-2.0 mix run test/fixtures/duckdb_2_0/capture.exs
#
# Each fixture is a complete server response body as received over HTTP.

alias QuackDB.Protocol.Codec
alias QuackDB.Protocol.Message.ConnectionRequest
alias QuackDB.Protocol.Message.FetchRequest
alias QuackDB.Protocol.Message.PrepareRequest

dir = Path.dirname(__ENV__.file)
duckdb = System.fetch_env!("QUACKDB_TEST_DUCKDB")
token = "quackdb-fixture-token"
port = 24_000 + :rand.uniform(1_000)

# Shredded VARIANT columns only exist in checkpointed storage.
database = Path.join(System.tmp_dir!(), "quackdb-fixtures-#{port}.duckdb")
File.rm(database)

{:ok, server} =
  QuackDB.Server.start_link(
    duckdb: duckdb,
    database: database,
    endpoint: "quack:localhost:#{port}",
    token: token,
    settings: [threads: 1],
    wait_timeout: 20_000
  )

{:ok, uri} = server |> QuackDB.Server.uri() |> QuackDB.URI.normalize()
{:ok, transport} = QuackDB.Transport.start_link(uri)

post = fn message, connection_id ->
  body = Codec.encode(message, connection_id: connection_id)
  {:ok, response} = QuackDB.Transport.post(transport, uri, body, [])
  response
end

save = fn name, response ->
  File.write!(Path.join(dir, name), response)
  IO.puts("wrote #{name} (#{byte_size(response)} bytes)")
  response
end

connection_response =
  save.(
    "connection_response.bin",
    post.(%ConnectionRequest{auth_string: token, client_duckdb_version: "quackdb/fixture"}, "")
  )

{:ok, {header, _response}} = Codec.decode(connection_response)
connection_id = header.connection_id

prepare = fn sql, uuid, inline_rows ->
  post.(
    %PrepareRequest{sql_query: sql, query_uuid: uuid, inline_rows: inline_rows},
    connection_id
  )
end

save.(
  "prepare_response_scalar.bin",
  prepare.(
    """
    SELECT * FROM (VALUES
      (1, 'duck', true, 123.45::DECIMAL(8, 2), DATE '2026-05-25', TIME '12:34:56.123456',
       TIMESTAMP '2026-05-25 12:34:56.123456', TIMESTAMPTZ '2026-05-25 12:34:56.123456+00',
       '\\x01\\x02\\x03'::BLOB),
      (2, NULL, false, -1.25::DECIMAL(8, 2), NULL, TIME '00:00:00',
       TIMESTAMP '1970-01-01 00:00:00', NULL, ''::BLOB)
    ) AS t(id, name, active, amount, event_date, event_time, happened_at, happened_tz, payload)
    ORDER BY id
    """,
    1,
    nil
  )
)

save.(
  "prepare_response_nested.bin",
  prepare.(
    """
    SELECT * FROM (VALUES
      (1, ['duck', 'analytics'], {'source': 'sensor', 'count': 2}, [10, 20, 30]::INTEGER[3],
       MAP {'env': 'test'}),
      (2, []::VARCHAR[], {'source': 'batch', 'count': NULL}, [40, 50, 60]::INTEGER[3],
       NULL::MAP(VARCHAR, VARCHAR))
    ) AS t(id, tags, metadata, scores, labels)
    ORDER BY id
    """,
    2,
    nil
  )
)

save.("error_response_catalog.bin", prepare.("SELECT * FROM missing_fixture_table", 3, nil))

# A small target batch size forces several fetch batches for a modest result.
prepare.("SET quack_target_batch_bytes = 4096", 4, nil)
prepare.("SELECT range AS i, range::VARCHAR AS s FROM range(5000)", 5, 0)

save.(
  "fetch_response_batch.bin",
  post.(%FetchRequest{query_uuid: 5, batch_index: 1, ack_index: 0}, connection_id)
)

Stream.iterate(2, &(&1 + 1))
|> Enum.reduce_while(nil, fn batch_index, _acc ->
  response =
    post.(
      %FetchRequest{query_uuid: 5, batch_index: batch_index, ack_index: batch_index - 1},
      connection_id
    )

  case Codec.decode(response) do
    {:ok, {_header, %{results: []}}} -> {:halt, save.("fetch_response_terminal.bin", response)}
    {:ok, _batch} -> {:cont, nil}
  end
end)

save.(
  "prepare_response_variant.bin",
  prepare.(
    """
    SELECT v FROM (VALUES
      (42::VARIANT), ('duck'::VARIANT), (NULL::VARIANT),
      ({'a': 1, 'b': [true::VARIANT, NULL, 2.5::DECIMAL(4, 1)::VARIANT]}::VARIANT),
      (DATE '2026-01-02'::VARIANT), ([]::INTEGER[]::VARIANT)
    ) AS t(v)
    """,
    6,
    nil
  )
)

# DuckDB only shreds row groups of at least 30,000 rows by default.
prepare.("SET variant_minimum_shredding_size = 1", 12, nil)
prepare.("CREATE TABLE fixture_variants (id INTEGER, v VARIANT)", 7, nil)

# Quack forwards a scanned vector unchanged only when it is a full 2048-row
# vector, so the irregular rows come first and fill one vector with the rest.
prepare.(
  """
  INSERT INTO fixture_variants VALUES
    (5000, {'n': 1, 'extra': 'left over'}::VARIANT), (5001, 7::VARIANT), (5002, NULL)
  """,
  9,
  nil
)

prepare.(
  """
  INSERT INTO fixture_variants
  SELECT i, {'n': i, 'nested': {'k': i % 3}}::VARIANT FROM range(2045) t(i)
  """,
  8,
  nil
)

prepare.("CHECKPOINT", 10, nil)

save.(
  "prepare_response_shredded_variant.bin",
  prepare.(
    "SELECT id, v FROM fixture_variants",
    11,
    nil
  )
)

GenServer.stop(transport)
GenServer.stop(server)
File.rm(database)
File.rm(database <> ".wal")
