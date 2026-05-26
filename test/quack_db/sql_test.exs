defmodule QuackDB.SQLTest do
  use ExUnit.Case, async: true

  test "builds INSTALL and LOAD statements" do
    assert QuackDB.SQL.install(:quack) |> IO.iodata_to_binary() == "INSTALL quack;"
    assert QuackDB.SQL.load(:quack) |> IO.iodata_to_binary() == "LOAD quack;"
  end

  test "builds CALL statements with positional and named arguments" do
    assert QuackDB.SQL.call(:quack_serve, ["quack:localhost"], token: "super_secret")
           |> IO.iodata_to_binary() ==
             "CALL quack_serve('quack:localhost', token = 'super_secret');"
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
