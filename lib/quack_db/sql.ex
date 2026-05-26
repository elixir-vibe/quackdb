defmodule QuackDB.SQL do
  @moduledoc """
  Client-side SQL parameter formatting for DuckDB Quack queries.

  DuckDB's current Quack protocol request shape does not expose server-side bind
  parameters. QuackDB therefore formats positional `?` placeholders as DuckDB SQL
  literals before sending a `PrepareRequest`.

  The formatter scans SQL and ignores placeholders inside quoted strings and SQL
  comments. It supports conservative scalar values and raises `QuackDB.Error` for
  unsupported parameter shapes rather than producing lossy SQL.
  """

  alias QuackDB.Error

  @type parameter ::
          nil
          | boolean()
          | integer()
          | float()
          | String.t()
          | Decimal.t()
          | Date.t()
          | Time.t()
          | NaiveDateTime.t()
          | DateTime.t()
          | QuackDB.Interval.t()
          | {:blob, binary()}
          | {:interval, integer(), integer(), integer()}
          | [parameter()]

  @spec format(iodata(), [parameter()]) :: {:ok, String.t()} | {:error, Error.t()}
  def format(statement, []), do: {:ok, IO.iodata_to_binary(statement)}

  def format(statement, params) when is_list(params) do
    statement = IO.iodata_to_binary(statement)

    with {:ok, formatted, used_count} <- scan(statement, params) do
      if used_count == length(params) do
        {:ok, formatted}
      else
        error(
          :parameter_count_mismatch,
          "SQL has #{used_count} positional placeholders but #{length(params)} parameters were provided"
        )
      end
    end
  end

  def format(_statement, params) do
    raise ArgumentError, "expected params to be a list, got: #{inspect(params)}"
  end

  @doc "Builds an `INSTALL extension;` statement."
  @spec install(atom() | String.t()) :: iodata()
  def install(extension) do
    ["INSTALL ", identifier!(extension, :extension), ";"]
  end

  @doc "Builds a `LOAD extension;` statement."
  @spec load(atom() | String.t()) :: iodata()
  def load(extension) do
    ["LOAD ", identifier!(extension, :extension), ";"]
  end

  @doc "Builds a `SET name = value;` statement."
  @spec set(atom() | String.t(), parameter()) :: iodata()
  def set(name, value), do: ["SET ", identifier!(name, :setting), " = ", literal!(value), ";"]

  @doc "Builds a `SET GLOBAL name = value;` statement."
  @spec set_global(atom() | String.t(), parameter()) :: iodata()
  def set_global(name, value),
    do: ["SET GLOBAL ", identifier!(name, :setting), " = ", literal!(value), ";"]

  @doc "Builds a `CALL function(args..., option = value...);` statement."
  @spec call(atom() | String.t(), [parameter()], keyword(parameter())) :: iodata()
  def call(function, positional_args \\ [], named_args \\ [])
      when is_list(positional_args) and is_list(named_args) do
    [
      "CALL ",
      identifier!(function, :function),
      "(",
      call_arguments(positional_args, named_args),
      ");"
    ]
  end

  @spec literal(parameter()) :: {:ok, iodata()} | {:error, Error.t()}
  def literal(nil), do: {:ok, "NULL"}
  def literal(true), do: {:ok, "TRUE"}
  def literal(false), do: {:ok, "FALSE"}
  def literal(value) when is_integer(value), do: {:ok, Integer.to_string(value)}

  def literal(value) when is_float(value) do
    if finite_float?(value) do
      {:ok, :io_lib_format.fwrite_g(value)}
    else
      error(:unsupported_parameter, "cannot encode non-finite SQL float #{inspect(value)}")
    end
  end

  def literal(%Decimal{} = value), do: {:ok, Decimal.to_string(value, :normal)}
  def literal(%Date{} = value), do: {:ok, ["DATE '", Date.to_iso8601(value), "'"]}
  def literal(%Time{} = value), do: {:ok, ["TIME '", Time.to_iso8601(value), "'"]}

  def literal(%NaiveDateTime{} = value) do
    {:ok, ["TIMESTAMP '", value |> NaiveDateTime.to_iso8601() |> String.replace("T", " "), "'"]}
  end

  def literal(%DateTime{} = value) do
    {:ok, ["TIMESTAMPTZ '", DateTime.to_iso8601(value), "'"]}
  end

  def literal(%QuackDB.Interval{} = interval) do
    literal({:interval, interval.months, interval.days, interval.microseconds})
  end

  if Code.ensure_loaded?(Geo.WKB) do
    for module <- [
          Geo.Point,
          Geo.PointZ,
          Geo.PointM,
          Geo.PointZM,
          Geo.LineString,
          Geo.LineStringZ,
          Geo.LineStringZM,
          Geo.Polygon,
          Geo.PolygonZ,
          Geo.MultiPoint,
          Geo.MultiPointZ,
          Geo.MultiLineString,
          Geo.MultiLineStringZ,
          Geo.MultiLineStringZM,
          Geo.MultiPolygon,
          Geo.MultiPolygonZ,
          Geo.GeometryCollection
        ] do
      def literal(%unquote(module){} = value), do: geo_literal(value)
    end

    defp geo_literal(value) do
      {:ok, ["ST_GeomFromWKB(", literal!({:blob, QuackDB.Geometry.from_geo!(value)}), ")"]}
    end
  end

  def literal({:interval, months, days, micros})
      when is_integer(months) and is_integer(days) and is_integer(micros) do
    {:ok,
     [
       "INTERVAL '",
       Integer.to_string(months),
       " months ",
       Integer.to_string(days),
       " days ",
       Integer.to_string(micros),
       " microseconds'"
     ]}
  end

  def literal({:blob, value}) when is_binary(value) do
    {:ok, ["from_hex('", Base.encode16(value, case: :lower), "')"]}
  end

  def literal(value) when is_binary(value),
    do: {:ok, ["'", String.replace(value, "'", "''"), "'"]}

  def literal(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, literals} ->
      case literal(value) do
        {:ok, literal} -> {:cont, {:ok, [literal | literals]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, literals} -> {:ok, ["[", literals |> Enum.reverse() |> Enum.intersperse(", "), "]"]}
      {:error, error} -> {:error, error}
    end
  end

  def literal(value), do: unsupported_parameter(value)

  defp call_arguments(positional_args, named_args) do
    positional = Enum.map(positional_args, &literal!/1)

    named =
      Enum.map(named_args, fn {name, value} ->
        [identifier!(name, :argument), " = ", literal!(value)]
      end)

    (positional ++ named)
    |> Enum.intersperse(", ")
  end

  defp literal!(value) do
    case literal(value) do
      {:ok, literal} -> literal
      {:error, %Error{} = error} -> raise error
    end
  end

  defp unsupported_parameter(value) do
    error(:unsupported_parameter, "unsupported SQL parameter #{inspect(value)}")
  end

  defp identifier!(value, kind) when is_atom(value),
    do: value |> Atom.to_string() |> identifier!(kind)

  defp identifier!(<<first, rest::binary>> = value, kind)
       when first in ?A..?Z or first in ?a..?z or first == ?_ do
    if valid_identifier_rest?(rest) do
      value
    else
      invalid_identifier!(value, kind)
    end
  end

  defp identifier!(value, kind), do: invalid_identifier!(value, kind)

  defp valid_identifier_rest?(<<>>), do: true

  defp valid_identifier_rest?(<<char, rest::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char == ?_ do
    valid_identifier_rest?(rest)
  end

  defp valid_identifier_rest?(_value), do: false

  defp invalid_identifier!(value, kind) do
    raise ArgumentError, "invalid SQL #{kind} identifier: #{inspect(value)}"
  end

  defp scan(statement, params), do: scan(statement, params, 0, [])

  defp scan(<<>>, _params, index, output),
    do: {:ok, output |> Enum.reverse() |> IO.iodata_to_binary(), index}

  defp scan(<<"'", rest::binary>>, params, index, output) do
    {quoted, rest} = take_single_quoted(rest, ["'"])
    scan(rest, params, index, [quoted | output])
  end

  defp scan(<<"\"", rest::binary>>, params, index, output) do
    {quoted, rest} = take_double_quoted(rest, ["\""])
    scan(rest, params, index, [quoted | output])
  end

  defp scan(<<"--", rest::binary>>, params, index, output) do
    {comment, rest} = take_line_comment(rest, ["--"])
    scan(rest, params, index, [comment | output])
  end

  defp scan(<<"/*", rest::binary>>, params, index, output) do
    {comment, rest} = take_block_comment(rest, ["/*"])
    scan(rest, params, index, [comment | output])
  end

  defp scan(<<??, rest::binary>>, params, index, output) do
    case Enum.fetch(params, index) do
      {:ok, value} ->
        with {:ok, literal} <- literal(value) do
          scan(rest, params, index + 1, [literal | output])
        end

      :error ->
        error(:parameter_count_mismatch, "SQL has more positional placeholders than parameters")
    end
  end

  defp scan(<<char::utf8, rest::binary>>, params, index, output) do
    scan(rest, params, index, [<<char::utf8>> | output])
  end

  defp scan(<<char, rest::binary>>, params, index, output) do
    scan(rest, params, index, [<<char>> | output])
  end

  defp take_single_quoted(<<"''", rest::binary>>, output),
    do: take_single_quoted(rest, ["''" | output])

  defp take_single_quoted(<<"'", rest::binary>>, output),
    do: {output |> Enum.reverse(["'"]) |> IO.iodata_to_binary(), rest}

  defp take_single_quoted(<<char::utf8, rest::binary>>, output),
    do: take_single_quoted(rest, [<<char::utf8>> | output])

  defp take_single_quoted(<<char, rest::binary>>, output),
    do: take_single_quoted(rest, [<<char>> | output])

  defp take_single_quoted(<<>>, output),
    do: {output |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  defp take_double_quoted(<<"\"\"", rest::binary>>, output),
    do: take_double_quoted(rest, ["\"\"" | output])

  defp take_double_quoted(<<"\"", rest::binary>>, output),
    do: {output |> Enum.reverse(["\""]) |> IO.iodata_to_binary(), rest}

  defp take_double_quoted(<<char::utf8, rest::binary>>, output),
    do: take_double_quoted(rest, [<<char::utf8>> | output])

  defp take_double_quoted(<<char, rest::binary>>, output),
    do: take_double_quoted(rest, [<<char>> | output])

  defp take_double_quoted(<<>>, output),
    do: {output |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  defp take_line_comment(<<"\n", rest::binary>>, output),
    do: {output |> Enum.reverse(["\n"]) |> IO.iodata_to_binary(), rest}

  defp take_line_comment(<<char::utf8, rest::binary>>, output),
    do: take_line_comment(rest, [<<char::utf8>> | output])

  defp take_line_comment(<<char, rest::binary>>, output),
    do: take_line_comment(rest, [<<char>> | output])

  defp take_line_comment(<<>>, output),
    do: {output |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  defp take_block_comment(<<"*/", rest::binary>>, output),
    do: {output |> Enum.reverse(["*/"]) |> IO.iodata_to_binary(), rest}

  defp take_block_comment(<<char::utf8, rest::binary>>, output),
    do: take_block_comment(rest, [<<char::utf8>> | output])

  defp take_block_comment(<<char, rest::binary>>, output),
    do: take_block_comment(rest, [<<char>> | output])

  defp take_block_comment(<<>>, output),
    do: {output |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  defp finite_float?(value) do
    try do
      _binary = :erlang.float_to_binary(value)
      true
    rescue
      ArgumentError -> false
    end
  end

  defp error(code, message), do: {:error, Error.new(code, message, source: :client)}
end
