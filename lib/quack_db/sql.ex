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
          | Duration.t()
          | {:blob, binary()}
          | {:uuid, binary()}
          | {:json, term()}
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

  @doc """
  Builds an `EXPLAIN ...` or `EXPLAIN ANALYZE ...` statement.

  Pass `analyze: true` to run the query and include DuckDB execution timings.
  Pass `format: :json`, `:html`, `:graphviz`, `:mermaid`, or `:text` to use
  DuckDB's `EXPLAIN (FORMAT ...)` output.
  """
  @spec explain(iodata(), keyword()) :: iodata()
  def explain(statement, options \\ []) when is_list(options) do
    case {Keyword.get(options, :analyze, false), Keyword.fetch(options, :format)} do
      {false, :error} ->
        ["EXPLAIN ", statement]

      {true, :error} ->
        ["EXPLAIN ANALYZE ", statement]

      {analyze?, {:ok, format}} ->
        ["EXPLAIN (", explain_options(analyze?, format), ") ", statement]
    end
  end

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

  @doc "Builds a DuckDB `PIVOT` statement."
  @spec pivot(iodata(), keyword()) :: iodata()
  def pivot(source, options) when is_list(options) do
    on = required_option!(options, :on)
    using = required_option!(options, :using)

    [
      "PIVOT ",
      source_expr(source),
      " ON ",
      on |> List.wrap() |> Enum.map(&projection_expr/1) |> Enum.intersperse(", "),
      " USING ",
      using |> List.wrap() |> Enum.map(&aggregate_expr/1) |> Enum.intersperse(", "),
      pivot_group_by(options)
    ]
  end

  @doc "Builds a DuckDB `UNPIVOT` statement."
  @spec unpivot(iodata(), keyword()) :: iodata()
  def unpivot(source, options) when is_list(options) do
    on = required_option!(options, :on)
    name = Keyword.get(options, :name, :name)
    value = Keyword.get(options, :value, :value)

    [
      "UNPIVOT ",
      source_expr(source),
      " ON ",
      on |> List.wrap() |> Enum.map(&projection_expr/1) |> Enum.intersperse(", "),
      " INTO NAME ",
      QuackDB.Type.quote_identifier(name),
      " VALUE ",
      QuackDB.Type.quote_identifier(value)
    ]
  end

  @doc "Builds a DuckDB `GROUPING SETS (...)` grouping expression."
  @spec grouping_sets([[atom() | String.t() | {:expr, iodata()}]]) :: iodata()
  def grouping_sets(sets) when is_list(sets) do
    [
      "GROUPING SETS (",
      sets |> Enum.map(&grouping_set/1) |> Enum.intersperse(", "),
      ")"
    ]
  end

  @doc "Builds a DuckDB `ROLLUP (...)` grouping expression."
  @spec rollup([atom() | String.t() | {:expr, iodata()}]) :: iodata()
  def rollup(columns) when is_list(columns) do
    ["ROLLUP (", columns |> Enum.map(&projection_expr/1) |> Enum.intersperse(", "), ")"]
  end

  @doc "Builds a DuckDB `CUBE (...)` grouping expression."
  @spec cube([atom() | String.t() | {:expr, iodata()}]) :: iodata()
  def cube(columns) when is_list(columns) do
    ["CUBE (", columns |> Enum.map(&projection_expr/1) |> Enum.intersperse(", "), ")"]
  end

  @doc "Builds a DuckDB star expression such as `* EXCLUDE (...)` or `table.* REPLACE (...)`."
  @spec star(keyword()) :: iodata()
  def star(options \\ []) when is_list(options) do
    validate_star_filters!(options)

    [
      star_base(options),
      star_filter(options),
      star_exclude(options),
      star_replace(options),
      star_rename(options)
    ]
  end

  @doc "Builds a DuckDB `COLUMNS(...)` expression."
  @spec columns(:star | String.t() | [atom() | String.t()] | keyword(), keyword()) :: iodata()
  def columns(selector \\ :star, options \\ [])
  def columns(:star, options) when is_list(options), do: ["COLUMNS(", star(options), ")"]

  def columns(options, []) when is_list(options) do
    if Keyword.keyword?(options) do
      columns(:star, options)
    else
      ["COLUMNS(", literal!(Enum.map(options, &to_string/1)), ")"]
    end
  end

  def columns(pattern, []) when is_binary(pattern), do: ["COLUMNS(", literal!(pattern), ")"]

  @doc "Builds a DuckDB `*COLUMNS(...)` unpacked columns expression."
  @spec unpack_columns(:star | String.t() | [atom() | String.t()] | keyword(), keyword()) ::
          iodata()
  def unpack_columns(selector \\ :star, options \\ []) do
    ["*", columns(selector, options)]
  end

  @doc "Builds a DuckDB SQL literal or raises `QuackDB.Error` for unsupported values."
  @spec literal!(parameter()) :: iodata()
  def literal!(value) do
    case literal(value) do
      {:ok, literal} -> literal
      {:error, %Error{} = error} -> raise error
    end
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

  def literal(%Duration{} = duration) do
    {months, days, micros} = duration_to_interval(duration)
    literal({:interval, months, days, micros})
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

  def literal({:uuid, value}) when is_binary(value) do
    {:ok, ["UUID '", String.replace(value, "'", "''"), "'"]}
  end

  def literal({:json, value}) when is_binary(value) do
    {:ok, ["JSON '", String.replace(value, "'", "''"), "'"]}
  end

  if Code.ensure_loaded?(Jason) do
    def literal({:json, value}) do
      literal({:json, Jason.encode!(value)})
    end
  else
    def literal({:json, value}) do
      error(
        :unsupported_parameter,
        "cannot encode JSON SQL parameter without Jason: #{inspect(value)}"
      )
    end
  end

  def literal(value) when is_binary(value) do
    cond do
      String.valid?(value) and not String.contains?(value, <<0>>) ->
        {:ok, ["'", String.replace(value, "'", "''"), "'"]}

      byte_size(value) == 16 ->
        uuid_binary_literal(value)

      true ->
        binary_literal(value)
    end
  end

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

  defp required_option!(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing required option #{inspect(key)}"
    end
  end

  defp pivot_group_by(options) do
    case Keyword.get(options, :group_by, []) |> List.wrap() do
      [] -> []
      columns -> [" GROUP BY ", columns |> Enum.map(&projection_expr/1) |> Enum.intersperse(", ")]
    end
  end

  defp grouping_set(columns) when is_list(columns) do
    ["(", columns |> Enum.map(&projection_expr/1) |> Enum.intersperse(", "), ")"]
  end

  defp source_expr({:expr, expression}), do: expression
  defp source_expr(value), do: QuackDB.Type.quote_identifier(value)

  defp projection_expr({:expr, expression}), do: expression
  defp projection_expr(value), do: QuackDB.Type.quote_identifier(value)

  defp aggregate_expr({:expr, expression}), do: expression

  defp aggregate_expr({function, column}) when is_atom(function) do
    [identifier!(function, :aggregate), "(", projection_expr(column), ")"]
  end

  defp aggregate_expr({function, column, alias_name}) when is_atom(function) do
    [
      identifier!(function, :aggregate),
      "(",
      projection_expr(column),
      ") AS ",
      QuackDB.Type.quote_identifier(alias_name)
    ]
  end

  defp aggregate_expr(expression), do: expression

  defp star_base(options) do
    case Keyword.fetch(options, :qualifier) do
      {:ok, qualifier} -> [QuackDB.Type.quote_identifier(qualifier), ".*"]
      :error -> "*"
    end
  end

  defp star_filter(options) do
    filters = Enum.filter([:like, :glob, :similar_to], &Keyword.has_key?(options, &1))

    case filters do
      [] ->
        []

      [filter] ->
        [" ", star_filter_operator(filter), " ", literal!(Keyword.fetch!(options, filter))]

      [_first | _rest] ->
        raise ArgumentError, "expected at most one star pattern filter"
    end
  end

  defp star_filter_operator(:like), do: "LIKE"
  defp star_filter_operator(:glob), do: "GLOB"
  defp star_filter_operator(:similar_to), do: "SIMILAR TO"

  defp star_exclude(options) do
    case Keyword.get(options, :exclude, []) |> List.wrap() do
      [] ->
        []

      names ->
        [
          " EXCLUDE (",
          names |> Enum.map(&QuackDB.Type.quote_identifier/1) |> Enum.intersperse(", "),
          ")"
        ]
    end
  end

  defp star_replace(options) do
    case Keyword.get(options, :replace, []) do
      [] ->
        []

      replacements ->
        [
          " REPLACE (",
          replacements |> Enum.map(&replacement_expr/1) |> Enum.intersperse(", "),
          ")"
        ]
    end
  end

  defp replacement_expr({name, {:expr, expression}}),
    do: [expression, " AS ", QuackDB.Type.quote_identifier(name)]

  defp replacement_expr({name, value}) do
    raise ArgumentError,
          "expected replacement for #{inspect(name)} to be {:expr, sql}, got: #{inspect(value)}"
  end

  defp star_rename(options) do
    case Keyword.get(options, :rename, []) do
      [] -> []
      renames -> [" RENAME (", renames |> Enum.map(&rename_expr/1) |> Enum.intersperse(", "), ")"]
    end
  end

  defp rename_expr({from, to}),
    do: [QuackDB.Type.quote_identifier(from), " AS ", QuackDB.Type.quote_identifier(to)]

  defp validate_star_filters!(options) do
    if Enum.any?([:like, :glob, :similar_to], &Keyword.has_key?(options, &1)) and
         Keyword.has_key?(options, :exclude) do
      raise ArgumentError, "star pattern filters cannot be combined with :exclude"
    end
  end

  defp duration_to_interval(%Duration{} = duration) do
    months = duration.year * 12 + duration.month
    days = duration.week * 7 + duration.day
    {microseconds, _precision} = duration.microsecond

    micros =
      microseconds +
        duration.second * 1_000_000 +
        duration.minute * 60 * 1_000_000 +
        duration.hour * 60 * 60 * 1_000_000

    {months, days, micros}
  end

  defp explain_options(analyze?, format) do
    options =
      if analyze? do
        ["ANALYZE", "FORMAT " <> explain_format(format)]
      else
        ["FORMAT " <> explain_format(format)]
      end

    Enum.intersperse(options, ", ")
  end

  defp explain_format(format) when format in [:text, :json, :html, :graphviz, :mermaid],
    do: Atom.to_string(format)

  defp explain_format(format) when format in ["text", "json", "html", "graphviz", "mermaid"],
    do: format

  defp explain_format(format) do
    raise ArgumentError,
          "expected explain format to be :text, :json, :html, :graphviz, or :mermaid, got: #{inspect(format)}"
  end

  defp call_arguments(positional_args, named_args) do
    positional = Enum.map(positional_args, &literal!/1)

    named =
      Enum.map(named_args, fn {name, value} ->
        [identifier!(name, :argument), " = ", literal!(value)]
      end)

    (positional ++ named)
    |> Enum.intersperse(", ")
  end

  if Code.ensure_loaded?(Ecto.UUID) do
    defp uuid_binary_literal(value) do
      case Ecto.UUID.load(value) do
        {:ok, uuid} -> literal({:uuid, uuid})
        :error -> binary_literal(value)
      end
    end
  else
    defp uuid_binary_literal(value), do: binary_literal(value)
  end

  defp binary_literal(value), do: literal({:blob, value})

  defp unsupported_parameter(value) do
    error(:unsupported_parameter, "unsupported SQL parameter #{inspect(value)}")
  end

  defp identifier!(value, kind) do
    if QuackDB.Identifier.valid?(value) do
      to_string(value)
    else
      invalid_identifier!(value, kind)
    end
  end

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
