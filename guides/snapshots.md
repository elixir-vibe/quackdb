# Snapshots and Time Travel

Delta and DuckLake tables keep their history. Every commit creates a snapshot,
and DuckDB reads a table as it was at any snapshot that has not expired. QuackDB
exposes that through Ecto with `QuackDB.Ecto.Snapshot`, and through SQL helpers
in `QuackDB.DuckLake`, `QuackDB.DDL`, and `QuackDB.Source`.

## Delta or DuckLake

Both formats keep data in Parquet files on local disk or object storage, and both
read past snapshots with the same `AT (...)` clause, so the Ecto API is the same.
They differ in what they record:

| | DuckLake | Delta |
| --- | --- | --- |
| Writes from DuckDB | `INSERT`, `UPDATE`, `DELETE` | `INSERT` only |
| Snapshot numbering | one per catalog, across all its tables | one per table |
| List snapshots | `DuckLake.snapshots/1` | not available in DuckDB |
| Rows changed between snapshots | `DuckLake.changes/3` | not available in DuckDB |
| Tag a commit | `DuckLake.set_commit_message/3` | not available |
| Metadata | a DuckDB, SQLite, or PostgreSQL catalog database | a `_delta_log` beside the data |
| Readers | DuckDB | Spark, Databricks, Polars, and other Delta readers |

Use **DuckLake** for application data that is updated and deleted, or when one
snapshot must describe several tables at once, such as replaying what an app's
database looked like at a moment. Use **Delta** for append-only data, or when
other engines read or write the same tables.

## DuckLake

Load the extension and attach a catalog. The metadata path and `:data_path` are
read by the DuckDB server:

```elixir
alias QuackDB.{DDL, DuckLake, Extension}

Repo.query!(Extension.install(:ducklake))
Repo.query!(Extension.load(:ducklake))
Repo.query!(DDL.attach("ducklake:/var/lib/app/lake.ducklake", :lake, data_path: "s3://bucket/lake/"))
```

Point Ecto schemas at the catalog with `@schema_prefix`, and read and write them
as usual. Each transaction commits one snapshot:

```elixir
defmodule MyApp.Order do
  use Ecto.Schema

  @schema_prefix "lake"
  schema "orders" do
    field :status, :string
    has_many :items, MyApp.Item
  end
end

Repo.insert!(%Order{status: "new"})
Repo.update_all(Order, set: [status: "paid"])
```

A DuckLake catalog kept in a DuckDB file can be attached once per server, so
read past snapshots through the attached catalog rather than attaching it again.

## Delta

Attach a Delta table with `type: :delta`. The attached database holds one table
with the same name:

```elixir
Repo.query!(Extension.install(:delta))
Repo.query!(Extension.load(:delta))
Repo.query!(DDL.attach("s3://bucket/events", :events, type: :delta))
Repo.query!(DDL.create_table({:events, :events}, id: :bigint, name: :varchar))

Repo.insert_all("events", [[id: 1, name: "signup"]])
```

Delta versions count each table's commits from 0, its creation. To read a Delta
table without attaching it, pass `:version` or `:timestamp` to `Source.delta/2`;
to attach it read-only at a version, pass `version:` to `DDL.attach/3`:

```elixir
from event in Source.delta("s3://bucket/events", version: 5), select: count()

Repo.query!(DDL.attach("s3://bucket/events", :events_v5, type: :delta, version: 5))
```

## Reading a snapshot

`QuackDB.Ecto.Snapshot.put_snapshot/2` reads every table in a query at a
snapshot. A `DateTime` reads the latest snapshot committed at or before it;
`version: n` reads a DuckLake snapshot id or a Delta table version:

```elixir
import QuackDB.Ecto.Snapshot

Order
|> join(:inner, [o], i in assoc(o, :items))
|> select([o, i], {o.status, i.name})
|> put_snapshot(~U[2026-10-20 14:03:11Z])
|> Repo.all()
```

The snapshot reaches joins, including assoc joins and their join tables,
subqueries, and CTE bodies. It skips CTE names, `values/2`, fragments, and
`QuackDB.Source` helpers.

Plain DuckDB tables keep no snapshots, so a query that joins one fails with
`Catalog type does not support time travel`. Give the snapshot to one named
binding with `put_snapshot/3`, which also overrides the query's snapshot, for
example to compare two versions:

```elixir
from(e in "events", as: :event, join: c in "countries", on: c.code == e.country, select: c.name)
|> put_snapshot(:event, version: 5)
```

Ecto drops hints on assoc joins while planning, so `put_snapshot/3` needs a binding
from `from` or a join on an explicit source.

### The :snapshot repo option

To give a whole repo call a snapshot, preloads included, delegate the repo's
`prepare_query/3` to `QuackDB.Ecto.Snapshot`:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.QuackDB

  @impl true
  defdelegate prepare_query(operation, query, opts), to: QuackDB.Ecto.Snapshot
end
```

```elixir
order = Repo.get!(Order, id, snapshot: event_at)
Repo.preload(order, :items, snapshot: event_at)

Order |> preload(:items) |> Repo.all(snapshot: [version: 42])
```

Ecto passes a call's options to its preload queries, so they read the same
snapshot. Snapshots are read-only: `update_all` and `delete_all` raise when
given one.

A timestamp before the first snapshot fails with `No snapshot found at timestamp`
on DuckLake and `no version exists at or before this timestamp` on Delta; both
reject timestamps in the future. Snapshot times come from the DuckDB server's
clock, so keep it in sync with the clocks that record the times you read at.

In raw SQL, write the clause after the table's alias:

```sql
SELECT o.status FROM lake.orders AS o AT (VERSION => 42)
SELECT count(*) FROM events AT (TIMESTAMP => TIMESTAMPTZ '2026-10-20 14:03:11+00')
```

## Listing DuckLake snapshots

`DuckLake.snapshots/1` and `DuckLake.current_snapshot/1` are table sources, so
Ecto queries them. To find the snapshot a moment saw:

```elixir
from snapshot in DuckLake.snapshots(:lake),
  where: snapshot.snapshot_time <= ^event_at,
  order_by: [desc: snapshot.snapshot_id],
  limit: 1,
  select: snapshot.snapshot_id
```

Snapshots have `snapshot_id`, `snapshot_time`, `schema_version`, `changes`, and
the `author`, `commit_message`, and `commit_extra_info` a transaction set with
`DuckLake.set_commit_message/3`. Tagging commits maps them to what wrote them
without comparing clocks:

```elixir
Repo.transaction(fn ->
  Repo.insert!(order)
  Repo.query!(DuckLake.set_commit_message(:lake, "checkout", extra_info: %{request_id: request_id}))
end)
```

## Rows changed between snapshots

`DuckLake.changes/3` reads the rows of one table that changed in snapshots
`:from` through `:to`, both included, with `snapshot_id`, `rowid`, and
`change_type`: `insert`, `delete`, `update_preimage`, or `update_postimage`.
`:from` and `:to` are snapshot ids, or `DateTime`s that take the snapshots
committed between them. `DuckLake.insertions/3` and `DuckLake.deletions/3`
read only inserted or deleted rows; an update deletes the row's old version
and inserts the new one.

```elixir
from change in DuckLake.changes(:lake, Order, from: 42, to: 42),
  order_by: [change.snapshot_id, change.rowid],
  select: %{type: change.change_type, id: change.id, status: change.status}
```

## Expiring snapshots

DuckLake keeps every snapshot until it expires. Expired snapshots can no longer
be read:

```elixir
Repo.query!(DuckLake.expire_snapshots(:lake, older_than: DateTime.add(DateTime.utc_now(), -30, :day)))
```

Delta versions last until a Delta writer cleans up the table's log and
vacuums its old files.
