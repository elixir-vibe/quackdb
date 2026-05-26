# Arrow and columnar handoff research

QuackDB currently receives DuckDB result data through Quack `DataChunk` messages and exposes row-oriented results, column-oriented helpers, `Table.Reader`, and Explorer conversion helpers.

## Current state

- Quack result batches are DuckDB vectors serialized in the Quack protocol, not Arrow IPC.
- `QuackDB.Columns` can avoid row-shaped access for callers that want columns.
- Explorer integration currently builds an `Explorer.DataFrame` from decoded Elixir column values.
- `Table.Reader` support makes results consumable by Livebook/Table-aware tooling, but it is not zero-copy.

## Zero-copy constraints

A zero-copy Explorer handoff would need one of these:

1. DuckDB Quack support for Arrow IPC or Arrow C data interface payloads.
2. A separate local DuckDB route that can export Arrow IPC and hand that binary to Explorer/Polars.
3. A native NIF/port bridge that maps DuckDB vectors or Arrow buffers directly.

The current pure-Elixir Quack decoder must materialize values into BEAM terms. That is correct and portable, but it is not zero-copy.

## Recommended direction

Keep the existing pure-Elixir protocol path as the default. For larger analytical handoffs, investigate a separate optional Arrow path rather than forcing Arrow into the Quack protocol abstraction prematurely.

Promising future work:

- Check whether future DuckDB Quack protocol versions expose Arrow IPC result payloads.
- Prototype `COPY (query) TO 'file.arrow' (FORMAT arrow)` through a server-visible path for local workflows.
- Evaluate DuckDB's ADBC/Arrow surfaces as a separate optional integration.
- Keep `QuackDB.Columns` and `Table.Reader` efficient for pure-Elixir workflows even if an Arrow path is added later.
