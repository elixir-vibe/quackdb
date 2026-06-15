# Telemetry

QuackDB emits `:telemetry` spans for direct query, append, and fetch operations.

## Events

With the default prefix, QuackDB emits:

```elixir
[:quackdb, :query, :start]
[:quackdb, :query, :stop]
[:quackdb, :append, :start]
[:quackdb, :append, :stop]
[:quackdb, :fetch, :start]
[:quackdb, :fetch, :stop]
```

Use `:telemetry_prefix` when starting the connection to align events with your application:

```elixir
children = [
  {QuackDB,
   uri: "http://[::1]:9494",
   token: "super_secret",
   telemetry_prefix: [:my_app, :quackdb]}
]
```

Then query events are emitted as:

```elixir
[:my_app, :quackdb, :query, :start]
[:my_app, :quackdb, :query, :stop]
```

## Metadata

Query start metadata includes:

```elixir
%{
  query: "SELECT ...",
  connection_id: "...",
  options: []
}
```

Query stop metadata includes:

```elixir
%{
  command: :select,
  rows: 42,
  result: :ok,
  encode_duration: 120_000,
  transport_duration: 8_000_000,
  decode_duration: 300_000,
  normalize_duration: 1_000_000,
  request_bytes: 240,
  response_bytes: 12_000_000
}
```

Duration values use Erlang native time units. Query `normalize_duration` covers response normalization, remaining fetches for non-streamed queries, and row materialization.

Append start metadata includes:

```elixir
%{
  query: "APPEND events",
  table: "events",
  schema: "",
  rows: 100_000,
  batches: 10,
  batch_size: 10_000,
  connection_id: "...",
  options: []
}
```

Append stop metadata includes the normal command/result fields plus append phase metrics. Duration values use Erlang native time units, matching the `:telemetry.span/3` measurement convention:

```elixir
%{
  command: :insert,
  rows: 100_000,
  result: :ok,
  batches: 10,
  encode_duration: 1_200_000,
  transport_duration: 8_000_000,
  decode_duration: 300_000,
  append_duration: 9_700_000,
  request_bytes: 12_000_000,
  response_bytes: 240,
  rows_per_second: 103_092.78
}
```

Fetch stop metadata includes:

```elixir
%{
  chunks: 3,
  result: :ok,
  encode_duration: 40_000,
  transport_duration: 2_000_000,
  decode_duration: 300_000,
  normalize_duration: 50_000,
  request_bytes: 80,
  response_bytes: 12_000_000
}
```

Errors are reported as stop metadata with `result: :error` and `error: %QuackDB.Error{}`.

## Custom operation metadata

Pass `:telemetry_options` to copy application context into telemetry metadata:

```elixir
QuackDB.query!(conn, "SELECT * FROM events", [],
  telemetry_options: [request_id: "req-1", job: :daily_rollup]
)
```

Parameters are omitted by default. Opt in explicitly when params are safe to expose:

```elixir
QuackDB.query!(conn, "SELECT ?", [1], telemetry_params: true)
```

## Minimal observer

```elixir
:telemetry.attach_many(
  "my-quackdb-observer",
  [[:quackdb, :query, :stop], [:quackdb, :append, :stop]],
  fn event, measurements, metadata, _config ->
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    IO.inspect({event, duration_ms, metadata})
  end,
  nil
)
```

See [`examples/query_observability.exs`](https://github.com/elixir-vibe/quackdb/blob/master/examples/query_observability.exs) for a runnable observer.
