Mix.install([
  {:quackdb, path: Path.expand("..", __DIR__)}
])

defmodule QuackDBTelemetryObserver do
  def handle_event([:quackdb, :query, :stop], measurements, metadata, _config) do
    IO.puts(
      "query #{inspect(metadata.command)} rows=#{metadata.rows} duration=#{format_native(measurements.duration)}ms"
    )
  end

  def handle_event([:quackdb, :append, :stop], measurements, metadata, _config) do
    IO.puts("append rows=#{metadata.rows} duration=#{format_native(measurements.duration)}ms")
  end

  def handle_event([:quackdb, :fetch, :stop], measurements, metadata, _config) do
    IO.puts("fetch chunks=#{metadata.chunks} duration=#{format_native(measurements.duration)}ms")
  end

  defp format_native(native) do
    native
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1_000)
    |> :erlang.float_to_binary(decimals: 2)
  end
end

uri = System.get_env("QUACKDB_TEST_URI", "http://localhost:9494")
token = System.get_env("QUACKDB_TEST_TOKEN", "super_secret")

:telemetry.attach_many(
  "quackdb-example-observer",
  [
    [:quackdb, :query, :stop],
    [:quackdb, :append, :stop],
    [:quackdb, :fetch, :stop]
  ],
  &QuackDBTelemetryObserver.handle_event/4,
  nil
)

{:ok, conn} = QuackDB.start_link(uri: uri, token: token)

table = "telemetry_events_#{System.unique_integer([:positive])}"

QuackDB.query!(conn, "CREATE TEMP TABLE #{table}(id INTEGER, name VARCHAR)")

QuackDB.insert_rows!(conn, table, [
  [id: 1, name: "duck"],
  [id: 2, name: "goose"]
])

result = QuackDB.query!(conn, "SELECT id, name FROM #{table} ORDER BY id")

IO.inspect(result.rows, label: "rows")
