defmodule QuackDB.FTS do
  @moduledoc """
  SQL helpers for DuckDB's full-text search extension.

  These helpers return iodata for DuckDB FTS statements and expressions. DuckDB
  autoloads the `fts` extension on first use in many configurations, but you can
  install/load it explicitly:

      alias QuackDB.FTS

      QuackDB.query!(conn, FTS.install())
      QuackDB.query!(conn, FTS.load())
      QuackDB.query!(conn, FTS.create_index("documents", :id, [:title, :body]))

      score = FTS.match_bm25(~s|"id"|, "duckdb analytics", schema: FTS.schema_name("main.documents"))
      QuackDB.query!(conn, ["SELECT id, ", score, " AS score FROM documents ORDER BY score DESC"])

  `bm25/3` and `search_score/3` are aliases for `match_bm25/3`. Use `stem/2`
  for DuckDB's stemming helper.
  """

  @type create_option ::
          {:stemmer, atom() | String.t()}
          | {:stopwords, atom() | String.t()}
          | {:ignore, String.t()}
          | {:strip_accents, boolean()}
          | {:lower, boolean()}
          | {:overwrite, boolean()}

  @type match_option ::
          {:fields, [atom() | String.t()] | atom() | String.t()}
          | {:k, number()}
          | {:b, number()}
          | {:conjunctive, boolean()}
          | {:schema, atom() | String.t()}

  @doc "Builds an `INSTALL fts;` statement."
  @spec install() :: iodata()
  def install, do: QuackDB.SQL.install(:fts)

  @doc "Builds a `LOAD fts;` statement."
  @spec load() :: iodata()
  def load, do: QuackDB.SQL.load(:fts)

  @doc "Builds `PRAGMA create_fts_index(...)`."
  @spec create_index(atom() | String.t(), atom() | String.t(), [atom() | String.t()] | :all, [
          create_option()
        ]) :: iodata()
  def create_index(table, id_column, columns, options \\ []) do
    args = [
      literal!(qualified_name(table)),
      literal!(id_column_name(id_column)) | indexed_columns(columns)
    ]

    [
      "PRAGMA create_fts_index(",
      Enum.intersperse(args ++ create_options(options), ", "),
      ");"
    ]
  end

  @doc "Builds `PRAGMA drop_fts_index(...)`."
  @spec drop_index(atom() | String.t()) :: iodata()
  def drop_index(table) do
    ["PRAGMA drop_fts_index(", literal!(qualified_name(table)), ");"]
  end

  @doc "Returns DuckDB's generated FTS schema name for a table."
  @spec schema_name(atom() | String.t()) :: String.t()
  def schema_name(table) do
    table
    |> qualified_name()
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
    |> then(&"fts_#{&1}")
  end

  @doc "Builds `match_bm25(id, query, ...)`."
  @spec match_bm25(iodata(), String.t(), [match_option()]) :: iodata()
  def match_bm25(id_expression, query, options \\ []) do
    args = [id_expression, literal!(query)] ++ match_options(options)
    [match_function(options), "(", Enum.intersperse(args, ", "), ")"]
  end

  @doc "Alias for `match_bm25/3`."
  @spec bm25(iodata(), String.t(), [match_option()]) :: iodata()
  def bm25(id_expression, query, options \\ []), do: match_bm25(id_expression, query, options)

  @doc "Alias for `match_bm25/3` when using the expression as a score/rank."
  @spec search_score(iodata(), String.t(), [match_option()]) :: iodata()
  def search_score(id_expression, query, options \\ []),
    do: match_bm25(id_expression, query, options)

  @doc "Builds `stem(text, stemmer)`."
  @spec stem(iodata(), atom() | String.t()) :: iodata()
  def stem(text_expression, stemmer \\ :porter) do
    ["stem(", text_expression, ", ", literal!(option_value(stemmer)), ")"]
  end

  defp indexed_columns(:all), do: [literal!("*")]

  defp indexed_columns(columns) when is_list(columns) do
    Enum.map(columns, &literal!(id_column_name(&1)))
  end

  defp indexed_columns(column), do: [literal!(id_column_name(column))]

  defp create_options(options) do
    Enum.map(options, fn
      {:stemmer, value} ->
        ["stemmer = ", literal!(option_value(value))]

      {:stopwords, value} ->
        ["stopwords = ", literal!(option_value(value))]

      {:ignore, value} ->
        ["ignore = ", literal!(value)]

      {:strip_accents, value} when is_boolean(value) ->
        ["strip_accents = ", boolean_option(value)]

      {:lower, value} when is_boolean(value) ->
        ["lower = ", boolean_option(value)]

      {:overwrite, value} when is_boolean(value) ->
        ["overwrite = ", boolean_option(value)]

      {key, _value} ->
        raise ArgumentError, "unsupported FTS create_index option #{inspect(key)}"
    end)
  end

  defp match_options(options) do
    options
    |> Keyword.delete(:schema)
    |> Enum.map(fn
      {:fields, value} -> ["fields := ", literal!(fields(value))]
      {:k, value} when is_number(value) -> ["k := ", literal!(value)]
      {:b, value} when is_number(value) -> ["b := ", literal!(value)]
      {:conjunctive, value} when is_boolean(value) -> ["conjunctive := ", boolean_option(value)]
      {key, _value} -> raise ArgumentError, "unsupported FTS match_bm25 option #{inspect(key)}"
    end)
  end

  defp match_function(options) do
    case Keyword.get(options, :schema) do
      nil -> "match_bm25"
      schema -> [quote_identifier(schema), ".match_bm25"]
    end
  end

  defp fields(values) when is_list(values), do: Enum.map_join(values, ", ", &id_column_name/1)

  defp fields(value), do: id_column_name(value)

  defp option_value(value) when is_atom(value), do: Atom.to_string(value)
  defp option_value(value), do: value

  defp qualified_name(value), do: value |> to_string() |> String.replace("\"", "\"\"")
  defp quote_identifier(value), do: ["\"", qualified_name(value), "\""]
  defp id_column_name(value), do: value |> to_string() |> String.replace("\"", "\"\"")

  defp boolean_option(true), do: "1"
  defp boolean_option(false), do: "0"

  defp literal!(value) do
    case QuackDB.SQL.literal(value) do
      {:ok, literal} -> literal
      {:error, error} -> raise error
    end
  end
end
