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
| `FLOAT` | `float()` | Supported | 32-bit floating point. |
| `DOUBLE` | `float()` | Supported | 64-bit floating point. |
| `DECIMAL` | `Decimal.t()` | Supported | Widths backed by 16-, 32-, 64-, and 128-bit storage are covered. |
| `VARCHAR` / `CHAR` | `String.t()` | Supported | Invalid UTF-8 raises a protocol error. |
| `BLOB` | `binary()` | Supported | Returned as raw bytes. |
| `UUID` | UUID string | Supported | Returned in canonical lowercase UUID format. |
| `ENUM` | `String.t()` | Supported | Returned as the enum label. |
| `BIT` | `String.t()` | Supported | Returned as a string of `0` and `1` characters. |
| `BIGNUM` | `integer()` | Supported | Decodes DuckDB's variable-length integer payload into an Elixir integer. |
| `GEOMETRY` | `binary()` | Partial | Decoded as WKB-compatible bytes when DuckDB's spatial extension returns geometry values; semantic geometry structs are not implemented. |

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

QuackDB formats query parameters as DuckDB SQL literals client-side because the current Quack request path does not expose server-side bind parameters.

Supported parameter values:

- `nil`
- booleans
- integers
- finite floats
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
- Result decoding is row-friendly today, but the protocol modules keep room for future columnar or Arrow-facing APIs.
- Type behavior is validated with gated real DuckDB Quack integration tests where DuckDB currently exposes the type through the Quack extension.
