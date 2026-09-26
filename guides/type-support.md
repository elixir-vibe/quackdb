# Type support

QuackDB decodes DuckDB Quack result vectors into Elixir values. The table below reflects the current package behavior and is intentionally conservative while both QuackDB and DuckDB's Quack protocol are experimental.

## Scalar types

| DuckDB type | Elixir value | Status | Notes |
| --- | --- | --- | --- |
| `BOOLEAN` | `boolean()` | Supported |  |
| `TINYINT` | `integer()` | Supported | Signed 8-bit. |
| `UTINYINT` | `non_neg_integer()` | Supported | Unsigned 8-bit. |
| `SMALLINT` | `integer()` | Supported | Signed 16-bit. |
| `USMALLINT` | `non_neg_integer()` | Supported | Unsigned 16-bit. |
| `INTEGER` | `integer()` | Supported | Signed 32-bit. |
| `UINTEGER` | `non_neg_integer()` | Supported | Unsigned 32-bit. |
| `BIGINT` | `integer()` | Supported | Signed 64-bit. |
| `UBIGINT` | `non_neg_integer()` | Supported | Unsigned 64-bit. |
| `HUGEINT` | `integer()` | Supported | Signed 128-bit. |
| `UHUGEINT` | `non_neg_integer()` | Supported | Unsigned 128-bit. |
| `FLOAT` | `float()`, `:nan`, `:infinity`, `:neg_infinity` | Supported | 32-bit floating point; see [Non-finite floats](#non-finite-floats). |
| `DOUBLE` | `float()`, `:nan`, `:infinity`, `:neg_infinity` | Supported | 64-bit floating point; see [Non-finite floats](#non-finite-floats). |
| `DECIMAL` | `Decimal.t()` | Supported | Widths backed by 16-, 32-, 64-, and 128-bit storage are covered. |
| `VARCHAR` / `CHAR` | `String.t()` | Supported | Invalid UTF-8 raises a protocol error. |
| `BLOB` | `binary()` | Supported | Returned as raw bytes. |
| `UUID` | UUID string | Supported | Returned in canonical lowercase UUID format. |
| `ENUM` | `String.t()` | Supported | Returned as the enum label. |
| `BIT` | `String.t()` | Supported | Returned as a string of `0` and `1` characters. |
| `BIGNUM` | `integer()` | Supported | Decodes DuckDB's variable-length integer payload into an Elixir integer. |
| `GEOMETRY` | `binary()` | Partial | Decoded as WKB-compatible bytes when DuckDB's spatial extension returns geometry values; semantic geometry structs are not implemented. |

Ecto schemas can use `:binary_id` or `Ecto.UUID` for UUID fields, including nullable fields and arrays. Schema reads return canonical UUID strings; SQL inserts and native append inserts preserve UUID values. Direct SQL results also remain canonical strings rather than Ecto's dumped 16-byte representation.

## Non-finite floats

DuckDB `FLOAT` and `DOUBLE` columns can hold IEEE 754 infinities and NaN, and the BEAM has no float for them: `<<x::float>>` refuses to build one. QuackDB represents them with the same atoms Explorer uses, so a result column hands to a dataframe without translation:

| DuckDB value | Elixir value |
| --- | --- |
| `'inf'` | `:infinity` |
| `'-inf'` | `:neg_infinity` |
| `'nan'` (any NaN payload, any sign) | `:nan` |

The atoms work in every direction:

```elixir
QuackDB.query!(conn, "SELECT 1.0/0.0 AS x, 'nan'::DOUBLE AS y").rows
#=> [[:infinity, :nan]]

QuackDB.query!(conn, "SELECT isnan(?)", [:nan]).rows
#=> [[true]]

QuackDB.insert_rows!(conn, "measurements", [[id: 1, ratio: :neg_infinity]])
```

As SQL parameters they are formatted as `'inf'::DOUBLE`, `'-inf'::DOUBLE`, and `'nan'::DOUBLE`; in native appends they are written as the IEEE bit patterns, with NaN as a quiet NaN.

Ecto's `:float` type accepts only numbers, so a schema field of type `:float` raises on load when the row holds one of these atoms, exactly as it does with Postgrex's `:NaN` and `:inf`. Direct SQL through the Repo returns the atoms unchanged. A schema that must carry non-finite values declares a custom type:

```elixir
defmodule MyApp.Measure do
  use Ecto.Type

  def type, do: :float

  def cast(value) when is_float(value) or value in [:nan, :infinity, :neg_infinity], do: {:ok, value}
  def cast(_), do: :error

  def load(value), do: cast(value)
  def dump(value), do: cast(value)
end
```

## Temporal types

| DuckDB type | Elixir value | Status | Notes |
| --- | --- | --- | --- |
| `DATE` | `Date.t()` | Supported |  |
| `TIME` | `Time.t()` | Supported | Microsecond precision. |
| `TIME_NS` | `QuackDB.NanosecondTime.t()` | Supported | Preserves nanoseconds since midnight. |
| `TIMESTAMP_S` | `NaiveDateTime.t()` | Supported | Second precision. |
| `TIMESTAMP_MS` | `NaiveDateTime.t()` | Supported | Millisecond precision. |
| `TIMESTAMP` | `NaiveDateTime.t()` | Supported | Microsecond precision. |
| `TIMESTAMP_NS` | `QuackDB.NanosecondTimestamp.t()` | Supported | Preserves nanoseconds since Unix epoch. |
| `TIME WITH TIME ZONE` | `QuackDB.TimeWithTimeZone.t()` | Supported | Preserves time-of-day and UTC offset seconds. |
| `TIMESTAMPTZ` | `DateTime.t()` | Supported | Decoded as UTC. |
| `INTERVAL` | `QuackDB.Interval.t()` | Supported | Preserves DuckDB month, day, and microsecond components. |

## Nested types

| DuckDB type | Elixir value | Status | Notes |
| --- | --- | --- | --- |
| `LIST` | list | Supported | Includes empty lists and null elements. |
| `STRUCT` | map with string keys | Supported | Null child values are preserved. |
| `ARRAY` | list | Supported | Fixed-size arrays are returned as Elixir lists. |
| `MAP` | map | Supported | Map entries are converted to Elixir maps; duplicate-key policy follows `Map.put/3`. |

## Append encoding

`QuackDB.insert_rows/4` supports scalar append values plus nested `LIST`, `STRUCT`, `ARRAY`, and `MAP` columns when explicit column specs are provided. Temporal append values use Elixir's Calendar conversion APIs and are encoded in DuckDB's ISO calendar representation.

Plain Elixir maps infer as DuckDB `STRUCT` values. For explicit `{:map, key_type, value_type}` columns, QuackDB accepts either DuckDB-style key/value entries or ordinary Elixir maps:

```elixir
QuackDB.insert_rows!(conn, "events", [[labels: %{env: "prod", region: "eu"}]],
  columns: [labels: {:map, :varchar, :varchar}]
)

QuackDB.insert_rows!(conn, "events", [[labels: [%{key: "env", value: "prod"}]]],
  columns: [labels: {:map, :varchar, :varchar}]
)
```

Both encode as DuckDB `MAP(VARCHAR, VARCHAR)`. Arbitrary mixed-key or mixed-value Elixir map semantics are not implied; DuckDB MAP columns still have one key type and one value type. Duplicate MAP keys decode with the later entry winning, matching `Map.put/3`. Keys and values are encoded through the declared DuckDB types, so atom keys in `{:map, :varchar, :varchar}` columns become strings.

## Vector encodings

| DuckDB vector encoding | Status |
| --- | --- |
| Flat | Supported |
| Constant | Supported |
| Dictionary | Supported |
| Sequence | Supported |
| FSST | Unsupported; QuackDB has an optional internal `:fsst` bridge, but current DuckDB Quack serialization flattens FSST vectors rather than exposing a compressed payload |

## SQL parameter literals

QuackDB formats query parameters as DuckDB SQL literals client-side because the current Quack request path does not expose server-side bind parameters. Pass values separately rather than interpolating them into SQL.

For direct queries, use `{:blob, bytes}` whenever the value is binary data, even if those bytes are valid UTF-8. Plain valid UTF-8 binaries without NUL are treated as text; relying on DuckDB to cast text into BLOB can interpret backslash escapes or reject non-ASCII bytes. Ecto schema `:binary` fields are explicitly encoded as blobs, including in native append inserts. Ecto `:naive_datetime_usec` and `:utc_datetime_usec` preserve microseconds; `TIMESTAMPTZ` results normalize to UTC rather than retaining the original time-zone name.

Supported parameter values:

- `nil`
- booleans
- integers
- floats, and the non-finite atoms `:nan`, `:infinity`, and `:neg_infinity`
- `Decimal.t()`
- strings
- `{:blob, binary}`
- `{:json, map_or_list_or_scalar}` when `Jason` is available
- `Date.t()`
- `Time.t()`
- `NaiveDateTime.t()`
- `DateTime.t()`
- `QuackDB.Interval.t()`
- `Duration.t()` values, converted to DuckDB interval literals and accepted by Ecto series/time-bucket helpers
- `{:interval, months, days, micros}`
- lists containing supported parameter values

Unsupported parameter values raise explicit errors rather than being formatted lossy.

## Notes

- Unsupported types should fail explicitly rather than silently returning lossy values.
- Result decoding supports row-shaped results and columnar fetch batches. Arrow IPC / zero-copy handoff remains future work.
- Type behavior is validated with gated real DuckDB Quack integration tests where DuckDB currently exposes the type through the Quack extension.
