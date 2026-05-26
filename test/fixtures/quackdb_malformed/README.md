# QuackDB malformed protocol fixtures

These fixtures are intentionally invalid Quack protocol payloads owned by QuackDB. They are not quack-ts conformance fixtures.

Use them for negative decoder tests: the decoder should return or raise a structured `QuackDB.Error`, not crash with an unrelated exception and not silently decode corrupted data.

## Fixtures

### `data_chunk_bignum_bad_size.bin`

Wrapped `DataChunk` with one `BIGNUM` column and one row.

The contained `BIGNUM` value is malformed: its payload header declares a two-byte magnitude, but the payload contains only one magnitude byte. Decoding should fail with `:invalid_bignum` and the message `BIGNUM payload size does not match header`.
