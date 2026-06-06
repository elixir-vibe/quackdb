defmodule QuackDB.Integration.TypeMatrixTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "decodes standalone null and boolean values" do
    assert [row] =
             query_rows!("""
             SELECT
               NULL AS sql_null,
               TRUE AS truthy,
               FALSE AS falsey,
               NULL::BOOLEAN AS nullable_bool,
               NULL::INTEGER AS nullable_integer
             """)

    assert row == [nil, true, false, nil, nil]
  end

  test "decodes integer family values" do
    assert [row] =
             query_rows!("""
             SELECT
               (-128)::TINYINT AS i8,
               255::UTINYINT AS u8,
               (-32768)::SMALLINT AS i16,
               65535::USMALLINT AS u16,
               (-2147483648)::INTEGER AS i32,
               4294967295::UINTEGER AS u32,
               (-9223372036854775808)::BIGINT AS i64,
               18446744073709551615::UBIGINT AS u64
             """)

    assert row == [
             -128,
             255,
             -32_768,
             65_535,
             -2_147_483_648,
             4_294_967_295,
             -9_223_372_036_854_775_808,
             18_446_744_073_709_551_615
           ]
  end

  test "decodes huge integer family values" do
    assert [row] =
             query_rows!("""
             SELECT
               170141183460469231731687303715884105727::HUGEINT AS huge,
               340282366920938463463374607431768211455::UHUGEINT AS uhuge
             """)

    assert row == [
             170_141_183_460_469_231_731_687_303_715_884_105_727,
             340_282_366_920_938_463_463_374_607_431_768_211_455
           ]
  end

  test "decodes floating point and decimal families" do
    assert [row] =
             query_rows!("""
             SELECT
               1.5::FLOAT AS f32,
               2.5::DOUBLE AS f64,
               12.34::DECIMAL(4,2) AS dec16,
               1234567.89::DECIMAL(9,2) AS dec32,
               1234567890123456.78::DECIMAL(18,2) AS dec64,
               123456789012345678901234567890123456.78::DECIMAL(38,2) AS dec128
             """)

    assert row == [
             1.5,
             2.5,
             Decimal.new("12.34"),
             Decimal.new("1234567.89"),
             Decimal.new("1234567890123456.78"),
             Decimal.new("123456789012345678901234567890123456.78")
           ]
  end

  test "decodes nullable floating point vectors with non-decodable null payloads" do
    rows =
      query_rows!("""
      SELECT CASE WHEN i % 10 = 0 THEN NULL::DOUBLE ELSE i * 1.25 END AS nullable_amount
      FROM range(0, 1000) AS t(i)
      ORDER BY i
      """)

    assert Enum.count(rows) == 1000
    assert Enum.at(rows, 0) == [nil]
    assert Enum.at(rows, 1) == [1.25]
    assert Enum.at(rows, 10) == [nil]
    assert Enum.at(rows, 999) == [1248.75]
  end

  test "decodes temporal values" do
    assert [row] =
             query_rows!("""
             SELECT
               TIME '12:34:56' AS t,
               CAST('00:00:01.234567890' AS TIME_NS) AS time_ns,
               CAST('00:00:01+01' AS TIME WITH TIME ZONE) AS time_tz,
               TIMESTAMP_S '2024-01-02 03:04:05' AS ts_s,
               TIMESTAMP_MS '2024-01-02 03:04:05.123' AS ts_ms,
               TIMESTAMP '2024-01-02 03:04:05.123456' AS ts_us,
               TIMESTAMP_NS '2024-01-02 03:04:05.123456789' AS ts_ns,
               TIMESTAMPTZ '2024-01-02 03:04:05+00' AS ts_tz
             """)

    assert row == [
             ~T[12:34:56.000000],
             QuackDB.NanosecondTime.new(1_234_567_890),
             QuackDB.TimeWithTimeZone.new(~T[00:00:01.000000], 3600),
             ~N[2024-01-02 03:04:05],
             ~N[2024-01-02 03:04:05.123],
             ~N[2024-01-02 03:04:05.123456],
             QuackDB.NanosecondTimestamp.new(1_704_164_645_123_456_789),
             ~U[2024-01-02 03:04:05.000000Z]
           ]
  end

  test "decodes misc scalar values" do
    assert [row] =
             query_rows!("""
             SELECT
               UUID '550e8400-e29b-41d4-a716-446655440000' AS uuid,
               BLOB 'hello' AS blob,
               'duck'::ENUM('duck', 'goose') AS enum_value,
               '10101'::BIT AS bits,
               123456789012345678901234567890::BIGNUM AS bignum,
               INTERVAL '1 month 2 days 3 microseconds' AS span
             """)

    assert row == [
             "550e8400-e29b-41d4-a716-446655440000",
             "hello",
             "duck",
             "10101",
             123_456_789_012_345_678_901_234_567_890,
             QuackDB.Interval.new(1, 2, 3)
           ]
  end

  test "decodes spatial geometry as WKB-compatible bytes" do
    connection = start_connection!()

    QuackDB.query!(connection, QuackDB.Spatial.load())

    geometry = QuackDB.Spatial.point(1, 2)

    assert %QuackDB.Result{rows: [[geometry, wkb, hexwkb]]} =
             QuackDB.query!(connection, [
               "SELECT ",
               geometry,
               " AS geometry, ",
               QuackDB.Spatial.as_wkb(geometry),
               " AS wkb, ",
               QuackDB.Spatial.as_hex_wkb(geometry),
               " AS hexwkb"
             ])

    assert geometry == wkb
    assert geometry == Base.decode16!(hexwkb, case: :mixed)
  end

  test "decodes empty result sets without losing columns" do
    connection = start_connection!()

    assert %QuackDB.Result{columns: ["id", "name"], rows: [], num_rows: 0} =
             QuackDB.query!(connection, "SELECT 1::INTEGER AS id, 'duck' AS name WHERE FALSE")
  end

  test "decodes nested edge cases" do
    assert [row] =
             query_rows!("""
             SELECT
               []::INTEGER[] AS empty_list,
               [1, NULL, 3] AS nullable_list,
               {'a': NULL, 'b': 2} AS nullable_struct,
               map(['a', 'b'], [NULL, 2]) AS nullable_map,
               [[1,2], [3,4]] AS nested_list,
               [NULL, [1, NULL], []]::INTEGER[][] AS nested_nullable_list
             """)

    assert row == [
             [],
             [1, nil, 3],
             %{"a" => nil, "b" => 2},
             %{"a" => nil, "b" => 2},
             [[1, 2], [3, 4]],
             [nil, [1, nil], []]
           ]
  end

  defp query_rows!(sql) do
    connection = start_connection!()
    QuackDB.query!(connection, sql).rows
  end
end
