# Full-text search

DuckDB's `fts` extension adds full-text indexes and BM25 ranking. QuackDB provides small SQL helpers for index management and Ecto helpers for search expressions.

## Load the extension

```elixir
alias QuackDB.FullTextSearch, as: FTS

QuackDB.query!(conn, FTS.install())
QuackDB.query!(conn, FTS.load())
```

DuckDB can autoload extensions in many environments, but explicit install/load keeps setup scripts and examples predictable.

## Create an index

```elixir
QuackDB.query!(
  conn,
  FTS.create_index("documents", :id, [:title, :body],
    stemmer: :porter,
    stopwords: :english,
    overwrite: true
  )
)
```

Use `:all` to index all `VARCHAR` columns:

```elixir
QuackDB.query!(conn, FTS.create_index("documents", :id, :all, overwrite: true))
```

Drop the generated index schema with:

```elixir
QuackDB.query!(conn, FTS.drop_index("documents"))
```

DuckDB creates a schema for each index. For `main.documents`, the generated schema is `fts_main_documents`. Use `FTS.schema_name/1` when building raw SQL fragments.

## Search from direct SQL

```elixir
schema = FTS.schema_name("main.documents")
score = FTS.match_bm25(~s|"id"|, "duckdb analytics", schema: schema)

QuackDB.query!(conn, [
  "SELECT id, title, ", score, " AS score ",
  "FROM documents WHERE ", score, " > 0 ",
  "ORDER BY score DESC"
])
```

`match_bm25/3` accepts DuckDB's BM25 options. `bm25/3` and `search_score/3` are aliases when those read better in query-building code:

```elixir
FTS.match_bm25(~s|"id"|, "duckdb analytics",
  schema: "fts_main_documents",
  fields: [:title, :body],
  k: 1.2,
  b: 0.75,
  conjunctive: false
)
```

## Search from Ecto

Import `QuackDB.Ecto.FullTextSearch` or `use QuackDB.Ecto`:

```elixir
import Ecto.Query
import QuackDB.Ecto.FullTextSearch

query =
  from doc in "documents",
    where: match_bm25("fts_main_documents", doc.id, ^"duckdb analytics") > 0,
    order_by: [desc: match_bm25("fts_main_documents", doc.id, ^"duckdb analytics")],
    select: %{
      id: doc.id,
      title: doc.title,
      score: match_bm25("fts_main_documents", doc.id, ^"duckdb analytics")
    }

MyApp.AnalyticsRepo.all(query)
```

For static query modules, pass the generated FTS schema as a literal string. For runtime table names, pin the schema name and the helper will emit an Ecto `identifier(^schema)` fragment:

```elixir
schema = QuackDB.FullTextSearch.schema_name("main.documents")

from doc in "documents",
  where: match_bm25(^schema, doc.id, ^"duckdb analytics") > 0,
  select: %{score: search_score(^schema, doc.id, ^"duckdb analytics")}
```

## Text stemming

DuckDB's FTS extension also exposes `stem`:

```elixir
QuackDB.query!(conn, ["SELECT ", FTS.stem("'running'", :english)])
```

In Ecto:

```elixir
from doc in "documents", select: stem(doc.body, ^"english")
```
