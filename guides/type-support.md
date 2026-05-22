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
| `BIT` | `binary()` | Partial | Returned as DuckDB's serialized bit bytes for now. |
| `BIGNUM` | — | Unsupported | Raises an explicit unsupported-type error. |
| `GEOMETRY` | `binary()` | Partial | Treated as raw bytes; semantic geometry decoding is not implemented. |

## Temporal types

| DuckDB type | Elixir value | Status | Notes |
| --- | --- | --- | --- |
| `DATE` | `Date.t()` | Supported |  |
| `TIME` | `Time.t()` | Supported | Microsecond precision. |
| `TIME_NS` | `{:time_ns, integer()}` | Partial | Preserves nanoseconds as an integer until an Elixir representation is chosen. |
| `TIMESTAMP_S` | `NaiveDateTime.t()` | Supported | Second precision. |
| `TIMESTAMP_MS` | `NaiveDateTime.t()` | Supported | Millisecond precision. |
| `TIMESTAMP` | `NaiveDateTime.t()` | Supported | Microsecond precision. |
| `TIMESTAMP_NS` | `{:timestamp_ns, integer()}` | Partial | Preserves nanoseconds since Unix epoch as an integer. |
| `TIMESTAMPTZ` | `DateTime.t()` | Supported | Decoded as UTC. |
| `INTERVAL` | `{:interval, months, days, micros}` | Supported | Tagged tuple preserving DuckDB interval components. |

## Nested types

| DuckDB type | Elixir value | Status | Notes |
| --- | --- | --- | --- |
| `LIST` | list | Supported | Includes empty lists and null elements. |
| `STRUCT` | map with string keys | Supported | Null child values are preserved. |
| `ARRAY` | list | Supported | Fixed-size arrays are returned as Elixir lists. |
| `MAP` | map | Supported | Map entries are converted to Elixir maps; duplicate-key policy follows `Map.put/3`. |

## Vector encodings

| DuckDB vector encoding | Status |
| --- | --- |
| Flat | Supported |
| Constant | Supported |
| Dictionary | Supported |
| Sequence | Supported |
| FSST | Unsupported |

## Notes

- Unsupported types should fail explicitly rather than silently returning lossy values.
- Result decoding is row-friendly today, but the protocol modules keep room for future columnar or Arrow-facing APIs.
- Type behavior is validated with gated real DuckDB Quack integration tests where DuckDB currently exposes the type through the Quack extension.
