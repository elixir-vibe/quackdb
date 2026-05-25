defmodule QuackDB.Type do
  @moduledoc """
  DuckDB SQL type rendering shared by DDL and source helpers.

  The protocol codec has its own logical type metadata for decoding wire values.
  This module is the SQL-facing counterpart: it renders user-friendly type specs
  into DuckDB type names for generated SQL.
  """

  @scalar_types %{
    boolean: "BOOLEAN",
    bool: "BOOLEAN",
    tinyint: "TINYINT",
    smallint: "SMALLINT",
    integer: "INTEGER",
    int: "INTEGER",
    bigint: "BIGINT",
    utinyint: "UTINYINT",
    usmallint: "USMALLINT",
    uinteger: "UINTEGER",
    uint: "UINTEGER",
    ubigint: "UBIGINT",
    hugeint: "HUGEINT",
    uhugeint: "UHUGEINT",
    float: "FLOAT",
    real: "FLOAT",
    double: "DOUBLE",
    decimal: "DECIMAL",
    varchar: "VARCHAR",
    string: "VARCHAR",
    text: "VARCHAR",
    char: "CHAR",
    blob: "BLOB",
    json: "JSON",
    date: "DATE",
    time: "TIME",
    time_tz: "TIMETZ",
    time_ns: "TIME_NS",
    timestamp: "TIMESTAMP",
    timestamp_s: "TIMESTAMP_S",
    timestamp_ms: "TIMESTAMP_MS",
    timestamp_ns: "TIMESTAMP_NS",
    timestamp_tz: "TIMESTAMPTZ",
    timestamptz: "TIMESTAMPTZ",
    interval: "INTERVAL",
    uuid: "UUID",
    bit: "BIT",
    bignum: "BIGNUM",
    geometry: "GEOMETRY"
  }

  @type spec ::
          atom()
          | String.t()
          | {:varchar, pos_integer()}
          | {:char, pos_integer()}
          | {:decimal, pos_integer(), non_neg_integer()}
          | {:list, spec()}
          | {:array, spec(), pos_integer()}
          | {:map, spec(), spec()}
          | {:struct, keyword(spec()) | map()}

  @doc "Renders a DuckDB SQL type spec as iodata."
  @spec to_sql(spec()) :: iodata()
  def to_sql(type) when is_atom(type) do
    case Map.fetch(@scalar_types, type) do
      {:ok, sql} -> sql
      :error -> raise ArgumentError, "unsupported DuckDB column type: #{inspect(type)}"
    end
  end

  def to_sql({:varchar, size}), do: ["VARCHAR(", integer!(size), ")"]
  def to_sql({:char, size}), do: ["CHAR(", integer!(size), ")"]

  def to_sql({:decimal, width, scale}),
    do: ["DECIMAL(", integer!(width), ", ", integer!(scale), ")"]

  def to_sql({:list, child_type}), do: [to_sql(child_type), "[]"]
  def to_sql({:array, child_type, size}), do: [to_sql(child_type), "[", integer!(size), "]"]

  def to_sql({:map, key_type, value_type}),
    do: ["MAP(", to_sql(key_type), ", ", to_sql(value_type), ")"]

  def to_sql({:struct, fields}) when is_list(fields) or is_map(fields) do
    fields =
      fields |> Enum.map(fn {name, type} -> [quote_identifier(name), " ", to_sql(type)] end)

    ["STRUCT(", Enum.intersperse(fields, ", "), ")"]
  end

  def to_sql(type) when is_binary(type), do: type

  def to_sql(type) do
    raise ArgumentError, "unsupported DuckDB column type: #{inspect(type)}"
  end

  @doc "Renders an identifier with DuckDB SQL quoting."
  @spec quote_identifier(atom() | String.t()) :: iodata()
  def quote_identifier(value) when is_atom(value),
    do: value |> Atom.to_string() |> quote_identifier()

  def quote_identifier(value) when is_binary(value) do
    [~s("), String.replace(value, ~s("), ~s("")), ~s(")]
  end

  def quote_identifier(value) do
    raise ArgumentError, "expected identifier as atom or string, got: #{inspect(value)}"
  end

  defp integer!(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)

  defp integer!(value) do
    raise ArgumentError, "expected non-negative integer, got: #{inspect(value)}"
  end
end
