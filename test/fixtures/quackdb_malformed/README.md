# QuackDB malformed protocol fixtures

These fixtures are intentionally invalid Quack protocol payloads owned by QuackDB. They are not quack-ts conformance fixtures.

Use them for negative decoder tests: the decoder should return or raise a structured `QuackDB.Error`, not crash with an unrelated exception and not silently decode corrupted data.

## Fixtures

### `data_chunk_bignum_bad_size.bin`

Wrapped `DataChunk` with one `BIGNUM` column and one row.

The contained `BIGNUM` value is malformed: its payload header declares a two-byte magnitude, but the payload contains only one magnitude byte. Decoding should fail with `:invalid_bignum` and the message `BIGNUM payload size does not match header`.

### `data_chunk_extra_vector.bin`

Wrapped `DataChunk` declaring one row and zero logical types, but one encoded `INTEGER` vector in the column list.

The payload violates the `DataChunk` invariant before a vector can be paired with a logical type. Decoding should fail with `:data_chunk_type_mismatch` and the message `data chunk has more vectors than logical types`.

### `data_chunk_missing_vector.bin`

Wrapped `DataChunk` declaring one row and one `INTEGER` logical type, but zero vectors in the column list.

The payload is structurally complete but violates the `DataChunk` invariant that the number of vectors must match the number of logical types. Decoding should fail with `:data_chunk_type_mismatch` and the message `data chunk has 1 types and 0 columns`.
