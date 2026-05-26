# Sources, extensions, and secrets

DuckDB can scan local files, remote object stores, and lakehouse table formats directly. QuackDB exposes small SQL builders around those features so paths, options, extension names, and credentials are formatted consistently.

## Source helpers

`QuackDB.Source` builds DuckDB table-function fragments:

```elixir
alias QuackDB.Source

Source.csv("events.csv", header: true, columns: %{id: "INTEGER", name: "VARCHAR"})
#=> "read_csv('events.csv', header = TRUE, columns = {'id': 'INTEGER', 'name': 'VARCHAR'})"
```

Available helpers:

- `Source.parquet/2` → `read_parquet(...)`
- `Source.csv/2` → `read_csv(...)`
- `Source.json/2` → `read_json(...)`
- `Source.xlsx/2` → `read_xlsx(...)`
- `Source.delta/2` → `delta_scan(...)`
- `Source.iceberg/2` → `iceberg_scan(...)`

Use `Source.table_function/3` for a DuckDB table function that QuackDB does not wrap yet.

## Ecto queries

Source fragments can be used as Ecto sources for analytical reads:

```elixir
use QuackDB.Ecto

alias QuackDB.Source

source = Source.parquet("s3://bucket/events/*.parquet", hive_partitioning: true)

MyApp.AnalyticsRepo.all(
  from event in source,
    group_by: event.category,
    select: %{category: event.category, events: count()}
)
```

## Direct SQL queries

The same source fragments can be composed into direct QuackDB SQL when that is clearer:

```elixir
alias QuackDB.Source

source = Source.csv("events.csv", header: true)

QuackDB.query!(conn, [
  "SELECT category, count(*) AS events FROM ",
  source,
  " GROUP BY category ORDER BY category"
])
```

## Local files

A local path works when it is visible to the DuckDB server process:

```elixir
Source.parquet("/data/events/*.parquet")
Source.csv("file:///data/events.csv", header: true)
```

When QuackDB is connected to a remote DuckDB server, paths are resolved on the server side, not in the Elixir VM.

## HTTP and HTTPS

DuckDB reads HTTP(S) files through the `httpfs` extension:

```elixir
alias QuackDB.{Extension, Source}

QuackDB.query!(conn, Extension.install(:httpfs))
QuackDB.query!(conn, Extension.load(:httpfs))

source = Source.parquet("https://example.com/events.parquet")
```

HTTP credentials are configured with DuckDB secrets:

```elixir
alias QuackDB.Secret

QuackDB.query!(conn, Secret.http(name: :api, bearer_token: token))

QuackDB.query!(
  conn,
  Secret.http(
    name: :headers,
    extra_http_headers: %{"Authorization" => "Bearer #{token}"}
  )
)
```

## S3-compatible stores

DuckDB's `httpfs` extension supports S3 and S3-compatible storage such as MinIO, lakeFS, Cloudflare R2, Tigris, and Google Cloud Storage interoperability endpoints.

```elixir
alias QuackDB.{Extension, Secret, Source}

QuackDB.query!(conn, Extension.install(:httpfs))
QuackDB.query!(conn, Extension.load(:httpfs))
QuackDB.query!(conn, Secret.s3(provider: :credential_chain))

source = Source.parquet("s3://bucket/events/*.parquet", hive_partitioning: true)
```

Explicit S3 credentials:

```elixir
Secret.s3(
  key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
  secret: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
  region: "us-east-1",
  scope: "s3://bucket/prefix/"
)
```

Cloudflare R2:

```elixir
Secret.r2(
  account_id: System.fetch_env!("CLOUDFLARE_ACCOUNT_ID"),
  key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
  secret: System.fetch_env!("R2_SECRET_ACCESS_KEY")
)

Source.parquet("r2://bucket/events/*.parquet")
```

Google Cloud Storage via DuckDB's GCS secret type:

```elixir
Secret.gcs(
  key_id: System.fetch_env!("GCS_HMAC_KEY_ID"),
  secret: System.fetch_env!("GCS_HMAC_SECRET")
)

Source.parquet("gcs://bucket/events/*.parquet")
```

## Azure Blob Storage and ADLS

DuckDB reads Azure storage through the `azure` extension:

```elixir
alias QuackDB.{Extension, Secret, Source}

QuackDB.query!(conn, Extension.install(:azure))
QuackDB.query!(conn, Extension.load(:azure))

QuackDB.query!(
  conn,
  Secret.azure(provider: :credential_chain, account_name: "storage_account")
)

Source.parquet("az://container/events/*.parquet")
Source.parquet("abfss://filesystem/events/*.parquet")
```

## Hugging Face datasets

DuckDB can scan Hugging Face dataset files with `hf://` URLs through `httpfs`:

```elixir
alias QuackDB.{Extension, Secret, Source}

QuackDB.query!(conn, Extension.install(:httpfs))
QuackDB.query!(conn, Extension.load(:httpfs))

source =
  Source.parquet(
    "hf://datasets/datasets-examples/doc-formats-parquet-1/data/train-00000-of-00001.parquet"
  )
```

Private or gated datasets can use a Hugging Face secret:

```elixir
QuackDB.query!(conn, Secret.hugging_face(name: :hf_token, token: token))
```

## Lakehouse formats

DuckDB can scan Delta and Iceberg tables when the relevant extensions and storage credentials are configured:

```elixir
alias QuackDB.Source

Source.delta("s3://bucket/delta/events")
Source.iceberg("s3://bucket/warehouse/events")
```

Use Ecto or direct SQL around those fragments just like CSV and Parquet sources.
