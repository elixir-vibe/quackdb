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

  @sql_scalar_types %{
    "BOOLEAN" => :boolean,
    "BOOL" => :boolean,
    "TINYINT" => :tinyint,
    "SMALLINT" => :smallint,
    "INTEGER" => :integer,
    "INT" => :integer,
    "BIGINT" => :bigint,
    "UTINYINT" => :utinyint,
    "USMALLINT" => :usmallint,
    "UINTEGER" => :uinteger,
    "UINT" => :uinteger,
    "UBIGINT" => :ubigint,
    "HUGEINT" => :hugeint,
    "UHUGEINT" => :uhugeint,
    "FLOAT" => :float,
    "REAL" => :float,
    "DOUBLE" => :double,
    "DECIMAL" => :decimal,
    "VARCHAR" => :varchar,
    "STRING" => :varchar,
    "TEXT" => :varchar,
    "CHAR" => :char,
    "BLOB" => :blob,
    "JSON" => :json,
    "DATE" => :date,
    "TIME" => :time,
    "TIMETZ" => :time_tz,
    "TIME WITH TIME ZONE" => :time_tz,
    "TIME_NS" => :time_ns,
    "TIMESTAMP" => :timestamp,
    "TIMESTAMP_S" => :timestamp_s,
    "TIMESTAMP_MS" => :timestamp_ms,
    "TIMESTAMP_NS" => :timestamp_ns,
    "TIMESTAMPTZ" => :timestamp_tz,
    "TIMESTAMP WITH TIME ZONE" => :timestamp_tz,
    "INTERVAL" => :interval,
    "UUID" => :uuid,
    "BIT" => :bit,
    "BIGNUM" => :bignum,
    "GEOMETRY" => :geometry
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

  @doc "Parses a DuckDB SQL type name into a QuackDB type spec."
  @spec from_sql(String.t()) :: {:ok, spec()} | {:error, {:unsupported_sql_type, String.t()}}
  def from_sql(type) when is_binary(type) do
    type = normalize_sql_type(type)

    case parse_sql_type(type) do
      {:ok, spec, []} -> {:ok, spec}
      {:ok, _spec, _tokens} -> {:error, {:unsupported_sql_type, type}}
      :error -> {:error, {:unsupported_sql_type, type}}
    end
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

  defp normalize_sql_type(type) do
    type
    |> String.trim()
    |> String.upcase()
    |> String.split()
    |> Enum.join(" ")
  end

  defp parse_sql_type(type) do
    case Map.fetch(@sql_scalar_types, type) do
      {:ok, scalar} ->
        {:ok, scalar, []}

      :error ->
        type
        |> tokenize_sql_type()
        |> parse_type()
    end
  end

  defp tokenize_sql_type(type), do: type |> String.to_charlist() |> tokenize_sql_type([])

  defp tokenize_sql_type([], tokens), do: Enum.reverse(tokens)

  defp tokenize_sql_type([char | rest], tokens) when char in [?\s, ?\t, ?\n, ?\r],
    do: tokenize_sql_type(rest, tokens)

  defp tokenize_sql_type([char | rest], tokens) when char in [?(, ?), ?[, ?], ?,],
    do: tokenize_sql_type(rest, [<<char>> | tokens])

  defp tokenize_sql_type([char | _rest] = chars, tokens) when char in ?0..?9 do
    {digits, rest} = Enum.split_while(chars, &(&1 in ?0..?9))
    tokenize_sql_type(rest, [digits |> to_string() |> String.to_integer() | tokens])
  end

  defp tokenize_sql_type([?_ | _rest] = chars, tokens) do
    {identifier, rest} = Enum.split_while(chars, &identifier_char?/1)
    tokenize_sql_type(rest, [to_string(identifier) | tokens])
  end

  defp tokenize_sql_type([char | _rest] = chars, tokens) when char in ?A..?Z do
    {identifier, rest} = Enum.split_while(chars, &identifier_char?/1)
    tokenize_sql_type(rest, [to_string(identifier) | tokens])
  end

  defp tokenize_sql_type([char | rest], tokens), do: tokenize_sql_type(rest, [<<char>> | tokens])

  defp identifier_char?(char) when char in ?A..?Z, do: true
  defp identifier_char?(char) when char in ?0..?9, do: true
  defp identifier_char?(?_), do: true
  defp identifier_char?(_char), do: false

  defp parse_type(["MAP", "(" | tokens]) do
    with {:ok, key_type, ["," | tokens]} <- parse_type(tokens),
         {:ok, value_type, [")" | tokens]} <- parse_type(tokens) do
      parse_type_postfix({:map, key_type, value_type}, tokens)
    else
      _other -> :error
    end
  end

  defp parse_type(["DECIMAL", "(", width, ",", scale, ")" | tokens])
       when is_integer(width) and is_integer(scale),
       do: parse_type_postfix({:decimal, width, scale}, tokens)

  defp parse_type(["VARCHAR", "(", size, ")" | tokens]) when is_integer(size),
    do: parse_type_postfix({:varchar, size}, tokens)

  defp parse_type(["CHAR", "(", size, ")" | tokens]) when is_integer(size),
    do: parse_type_postfix({:char, size}, tokens)

  defp parse_type(tokens), do: parse_scalar_type(tokens)

  defp parse_scalar_type(tokens) do
    tokens
    |> scalar_type_prefixes([])
    |> Enum.reverse()
    |> Enum.find_value(fn {type, rest} ->
      case Map.fetch(@sql_scalar_types, type) do
        {:ok, scalar} -> parse_type_postfix(scalar, rest)
        :error -> nil
      end
    end)
    |> case do
      nil -> :error
      result -> result
    end
  end

  defp scalar_type_prefixes([token | rest], prefix) when is_binary(token) do
    prefix = [token | prefix]
    type = prefix |> Enum.reverse() |> Enum.join(" ")
    [{type, rest} | scalar_type_prefixes(rest, prefix)]
  end

  defp scalar_type_prefixes(_tokens, _prefix), do: []

  defp parse_type_postfix(type, ["[", "]" | tokens]),
    do: parse_type_postfix({:list, type}, tokens)

  defp parse_type_postfix(type, ["[", size, "]" | tokens]) when is_integer(size),
    do: parse_type_postfix({:array, type, size}, tokens)

  defp parse_type_postfix(type, tokens), do: {:ok, type, tokens}

  defp integer!(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)

  defp integer!(value) do
    raise ArgumentError, "expected non-negative integer, got: #{inspect(value)}"
  end
end
