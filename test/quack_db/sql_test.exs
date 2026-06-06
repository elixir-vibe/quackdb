defmodule QuackDB.SQLTest do
  use ExUnit.Case, async: true

  test "builds INSTALL and LOAD statements" do
    assert QuackDB.SQL.install(:quack) |> IO.iodata_to_binary() == "INSTALL quack;"
    assert QuackDB.SQL.load(:quack) |> IO.iodata_to_binary() == "LOAD quack;"
  end

  test "builds SET statements" do
    assert QuackDB.SQL.set(:threads, 8) |> IO.iodata_to_binary() == "SET threads = 8;"

    assert QuackDB.SQL.set_global(:quack_fetch_batch_chunks, 4) |> IO.iodata_to_binary() ==
             "SET GLOBAL quack_fetch_batch_chunks = 4;"
  end

  test "builds EXPLAIN statements" do
    assert QuackDB.SQL.explain("SELECT 1") |> IO.iodata_to_binary() == "EXPLAIN SELECT 1"

    assert QuackDB.SQL.explain("SELECT 1", analyze: true) |> IO.iodata_to_binary() ==
             "EXPLAIN ANALYZE SELECT 1"
  end

  test "builds CALL statements with positional and named arguments" do
    assert QuackDB.SQL.call(:quack_serve, ["quack:localhost"], token: "super_secret")
           |> IO.iodata_to_binary() ==
             "CALL quack_serve('quack:localhost', token = 'super_secret');"
  end

  test "builds DuckDB star and columns expressions" do
    assert QuackDB.SQL.star(exclude: [:payload, "debug flag"]) |> IO.iodata_to_binary() ==
             ~S[* EXCLUDE ("payload", "debug flag")]

    assert QuackDB.SQL.star(
             qualifier: :events,
             replace: [score: {:expr, ~S[coalesce("score", 0)]}],
             rename: [old_name: :name]
           )
           |> IO.iodata_to_binary() ==
             ~S["events".* REPLACE (coalesce("score", 0) AS "score") RENAME ("old_name" AS "name")]

    assert QuackDB.SQL.star(like: "metric_%") |> IO.iodata_to_binary() ==
             ~S[* LIKE 'metric_%']

    assert QuackDB.SQL.columns(exclude: [:id]) |> IO.iodata_to_binary() ==
             ~S[COLUMNS(* EXCLUDE ("id"))]

    assert QuackDB.SQL.columns("^(id|score)$") |> IO.iodata_to_binary() ==
             ~S[COLUMNS('^(id|score)$')]

    assert QuackDB.SQL.columns([:id, :score]) |> IO.iodata_to_binary() ==
             "COLUMNS(['id', 'score'])"

    assert QuackDB.SQL.unpack_columns("^metric_") |> IO.iodata_to_binary() ==
             ~S[*COLUMNS('^metric_')]
  end

  test "rejects invalid star expression combinations" do
    assert_raise ArgumentError, ~r/pattern filters cannot be combined/, fn ->
      QuackDB.SQL.star(like: "id%", exclude: [:name]) |> IO.iodata_to_binary()
    end

    assert_raise ArgumentError, ~r/expected replacement/, fn ->
      QuackDB.SQL.star(replace: [score: "score + 1"]) |> IO.iodata_to_binary()
    end
  end

  test "rejects invalid statement identifiers" do
    assert_raise ArgumentError, ~r/invalid SQL function identifier/, fn ->
      QuackDB.SQL.call("bad-name", [])
    end
  end

  test "formats positional parameters as DuckDB SQL literals" do
    assert {:ok, sql} =
             QuackDB.SQL.format(
               "SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?",
               [
                 nil,
                 true,
                 42,
                 1.5,
                 Decimal.new("12.34"),
                 "duck",
                 ~D[2024-01-02],
                 ~T[03:04:05],
                 ~N[2024-01-02 03:04:05],
                 ~U[2024-01-02 03:04:05Z]
               ]
             )

    assert sql ==
             "SELECT NULL, TRUE, 42, 1.5, 12.34, 'duck', DATE '2024-01-02', TIME '03:04:05', TIMESTAMP '2024-01-02 03:04:05', TIMESTAMPTZ '2024-01-02T03:04:05Z'"
  end

  test "escapes strings and ignores placeholders in strings and comments" do
    assert {:ok, sql} =
             QuackDB.SQL.format(
               "SELECT '?' AS literal, ? AS value -- ? comment\n/* ? block */",
               ["Robert'); DROP TABLE users;--"]
             )

    assert sql ==
             "SELECT '?' AS literal, 'Robert''); DROP TABLE users;--' AS value -- ? comment\n/* ? block */"
  end

  test "formats Geo structs as DuckDB geometry literals" do
    assert {:ok, sql} = QuackDB.SQL.literal(%Geo.Point{coordinates: {1.0, 2.0}, srid: nil})

    assert sql |> IO.iodata_to_binary() ==
             "ST_GeomFromWKB(from_hex('0101000000000000000000f03f0000000000000040'))"
  end

  test "keeps non-NUL valid UTF-8 control strings as string literals" do
    assert {:ok, sql} = QuackDB.SQL.format("SELECT ?", ["line\nfeed"])
    assert sql == "SELECT 'line\nfeed'"
  end

  test "formats NUL-containing binaries as blob literals" do
    assert {:ok, sql} = QuackDB.SQL.format("SELECT ?", [<<3, 2, 1, 0>>])
    assert sql == "SELECT from_hex('03020100')"
  end

  test "formats JSON values" do
    assert {:ok, sql} = QuackDB.SQL.format("SELECT ?", [{:json, %{name: "duck", scores: [1, 2]}}])
    assert sql == ~s|SELECT JSON '{"name":"duck","scores":[1,2]}'|
  end

  test "formats Elixir durations as DuckDB intervals" do
    assert {:ok, sql} =
             QuackDB.SQL.format("SELECT ?", [
               Duration.new!(year: 1, month: 2, week: 1, day: 3, hour: 4, minute: 5, second: 6)
             ])

    assert sql == "SELECT INTERVAL '14 months 10 days 14706000000 microseconds'"
  end

  test "formats blobs, intervals, and lists" do
    assert {:ok, sql} =
             QuackDB.SQL.format("SELECT ?, ?, ?", [
               {:blob, <<0, 1, 255>>},
               {:interval, 1, 2, 3},
               [1, "duck", nil]
             ])

    assert sql ==
             "SELECT from_hex('0001ff'), INTERVAL '1 months 2 days 3 microseconds', [1, 'duck', NULL]"
  end

  test "returns count mismatch errors" do
    assert {:error, %QuackDB.Error{code: :parameter_count_mismatch}} =
             QuackDB.SQL.format("SELECT ?, ?", [1])

    assert {:error, %QuackDB.Error{code: :parameter_count_mismatch}} =
             QuackDB.SQL.format("SELECT ?", [1, 2])
  end

  test "rejects unsupported parameter values" do
    assert {:error, %QuackDB.Error{code: :unsupported_parameter}} =
             QuackDB.SQL.format("SELECT ?", [%{bad: :param}])
  end
end
