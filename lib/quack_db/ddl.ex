defmodule QuackDB.DDL do
  import QuackDB.SQL.Fragment,
    only: [alias_name: 1, column: 1, column_list: 1, schema: 1, table: 1, check_constraint: 1]

  alias QuackDB.DDL.Check

  @moduledoc """
  Small DuckDB DDL SQL builders.

  These helpers return SQL iodata for common analytical setup tasks such as
  temporary tables in tests or notebooks. They are not an Ecto migration layer;
  execute the generated SQL with `QuackDB.query/4` or `Repo.query/3`.

      QuackDB.DDL.create_table("events",
        [
          id: :integer,
          name: :varchar,
          payload: :json,
          occurred_at: :timestamp
        ],
        temporary: true,
        if_not_exists: true
      )

  """

  @type column_type :: QuackDB.Type.spec()
  @type column ::
          {atom() | String.t(), column_type() | keyword()}
          | {atom() | String.t(), column_type(), keyword()}

  @type create_table_option ::
          {:temporary, boolean()}
          | {:if_not_exists, boolean()}
          | {:or_replace, boolean()}
          | {:as, iodata()}
          | Check.t()

  @doc """
  Builds one inline CHECK constraint from an expression.

  Bare identifiers refer to columns. Pin runtime values with `^`; use
  `field("column name")` or `field(^name)` for other column names. Supports
  comparisons (`==`, `!=`, `>`, `>=`, `<`, `<=`), `and`, `or`, `not`, and
  `is_nil/1`. Arithmetic, arbitrary function calls, and raw SQL are rejected.

      import QuackDB.DDL, only: [create_table: 3, check: 1]

      maximum = 100
      create_table(:events, [score: :integer],
        check(score >= 0 and score < ^maximum)
      )

  Return values are composable: pass a single check or a list of checks as
  `create_table/3`'s third argument. Table options can follow checks in that list:
  `[check(score >= 0), temporary: true]`.
  """
  defmacro check(expression) do
    expression = Check.expression_ast!(expression)
    quote do: %QuackDB.DDL.Check{expression: unquote(expression)}
  end

  @doc "Builds a `CREATE TABLE` statement from an Ecto schema module."
  @spec create_table(module()) :: iodata()
  def create_table(schema) when is_atom(schema), do: create_table(schema, [])

  @spec create_table(
          module() | String.t() | atom(),
          Check.t() | [create_table_option()] | [column()]
        ) ::
          iodata()
  def create_table(schema, %Check{} = check), do: create_table(schema, [check])

  def create_table(schema_or_name, options_or_columns) when is_list(options_or_columns) do
    cond do
      Enum.any?(options_or_columns, &match?({:as, _}, &1)) ->
        create_table_as_options(schema_or_name, options_or_columns)

      is_atom(schema_or_name) and Code.ensure_loaded?(schema_or_name) and
          function_exported?(schema_or_name, :__schema__, 1) ->
        create_table(
          schema_or_name.__schema__(:source),
          schema_columns(schema_or_name),
          options_or_columns
        )

      true ->
        create_table(schema_or_name, options_or_columns, [])
    end
  end

  @doc """
  Builds a `CREATE TABLE` statement.

      QuackDB.DDL.create_table("events", id: :integer, name: :varchar)
      QuackDB.DDL.create_table("events", [id: :integer], temporary: true)
      QuackDB.DDL.create_table("temp_events", EventSchema, temporary: true)

  Pass a single `check/1` value or a list for inline constraints:

      import QuackDB.DDL, only: [create_table: 3, check: 1]

      create_table(:events, [{:score, :integer, null: false}],
        [check(score >= 0), check(score < 100)]
      )

  Checks also work with schema-derived columns. Column names are quoted and
  values use the SQL literal codec, not raw predicate strings. CHECK permits
  NULL when its expression is unknown; use `null: false` to require a value.
  Checks cannot be combined with `:as`. DuckDB does not preserve supplied CHECK
  names reliably, so this API does not name checks or promise Ecto changeset
  constraint mapping. ALTER ADD/DROP CONSTRAINT remains unsupported.

  Pass `:as` to build `CREATE TABLE AS` from iodata or an Ecto query without pinned params:

      QuackDB.DDL.create_table("docs", as: query, temporary: true)
      QuackDB.DDL.create_table("docs", as: query, or_replace: true)
  """
  @spec create_table(
          String.t() | atom(),
          module() | [column()],
          Check.t() | [create_table_option()]
        ) ::
          iodata()
  def create_table(name, schema_or_columns, options \\ [])

  def create_table(name, schema_or_columns, %Check{} = check),
    do: create_table(name, schema_or_columns, [check])

  def create_table(name, schema, options) when is_atom(schema) and is_list(options) do
    if Code.ensure_loaded?(schema) and function_exported?(schema, :__schema__, 1) do
      create_table(name, schema_columns(schema), options)
    else
      create_table(name, [{schema, options}], [])
    end
  end

  def create_table(name, columns, options) when is_list(columns) and is_list(options) do
    {options, checks} = table_options!(options)
    assert_create_options!(options)

    [
      "CREATE ",
      or_replace(options),
      temporary(options),
      "TABLE ",
      if_not_exists(options),
      table(name),
      " (",
      columns(columns),
      Enum.map(checks, &[", ", check_constraint(&1)]),
      ")"
    ]
  end

  defp create_table_as(name, query, options) when is_list(options) do
    assert_create_options!(options)

    [
      "CREATE ",
      or_replace(options),
      temporary(options),
      "TABLE ",
      if_not_exists(options),
      table(name),
      " AS ",
      table_query(query)
    ]
  end

  defp create_table_as_options(name, options) do
    {options, checks} = table_options!(options)

    if checks != [] do
      raise ArgumentError, "CHECK constraints require explicit columns, not CREATE TABLE AS"
    end

    {query, options} = Keyword.pop!(options, :as)
    create_table_as(name, query, options)
  end

  @doc "Builds a `DROP TABLE` statement."
  @spec drop_table(String.t() | atom(), keyword()) :: iodata()
  def drop_table(name, options \\ []) when is_list(options) do
    ["DROP TABLE ", if_exists(options), table(name)]
  end

  @doc """
  Builds a standalone `CREATE SEQUENCE` statement.

  Names may be atoms, strings, or `{prefix, name}` tuples. Supported options are
  `:start` (integer), `:increment` (nonzero integer), and `:if_not_exists` (boolean).
  Other options raise rather than being silently ignored. Sequences can have
  gaps; do not use them when a gapless transactional counter is required.

      alias QuackDB.{DDL, Sequence}

      QuackDB.query!(conn, DDL.create_sequence(:task_keys, start: 1))
      Sequence.next_values(conn, :task_keys, 3)
      #=> [1, 2, 3]
  """
  @spec create_sequence(QuackDB.SQL.Fragment.table(), keyword()) :: iodata()
  def create_sequence(name, options \\ []) do
    options = Keyword.validate!(options, [:start, :increment, :if_not_exists])
    clauses = Enum.map(options, &sequence_option/1)
    ["CREATE SEQUENCE ", if_not_exists(options), table(name), clauses]
  end

  @doc "Builds a `DROP SEQUENCE` statement, optionally with `if_exists: true`."
  @spec drop_sequence(QuackDB.SQL.Fragment.table(), keyword()) :: iodata()
  def drop_sequence(name, options \\ []) do
    options = Keyword.validate!(options, [:if_exists])
    Enum.each(options, &sequence_option/1)
    ["DROP SEQUENCE ", if_exists(options), table(name)]
  end

  @doc """
  Builds a `CREATE SCHEMA` statement.

  A list names a nested schema, which DuckDB 2.0 creates inside its parent.
  In an Ecto migration:

      alias QuackDB.DDL

      def up do
        execute DDL.create_schema(:finance)
        execute DDL.create_schema([:finance, :reports])
        execute DDL.create_table({[:finance, :reports], :ledger}, id: :integer)
      end

  Supports `if_not_exists: true`.
  """
  @spec create_schema(QuackDB.SQL.Fragment.schema(), keyword()) :: iodata()
  def create_schema(name, options \\ []) do
    options = Keyword.validate!(options, if_not_exists: false)
    ["CREATE SCHEMA ", if_not_exists(options), schema(name)]
  end

  @doc "Builds a `DROP SCHEMA` statement. Supports `if_exists: true` and `cascade: true`."
  @spec drop_schema(QuackDB.SQL.Fragment.schema(), keyword()) :: iodata()
  def drop_schema(name, options \\ []) do
    options = Keyword.validate!(options, if_exists: false, cascade: false)

    [
      "DROP SCHEMA ",
      if_exists(options),
      schema(name),
      if(options[:cascade], do: " CASCADE", else: [])
    ]
  end

  @doc """
  Builds an `ATTACH` statement that attaches `path` as the database `name`.

  Options become DuckDB attach options, such as `:type`, `:read_only`, or a
  DuckLake `:data_path`. Atoms are written as keywords, other values as
  literals:

      alias QuackDB.DDL

      DDL.attach("ducklake:metadata.ducklake", :lake, data_path: "s3://bucket/lake/")
      DDL.attach("s3://bucket/events", :events, type: :delta)
      DDL.attach("s3://bucket/events", :events_v5, type: :delta, version: 5)

  Supports `if_not_exists: true`.
  """
  @spec attach(String.t(), atom() | String.t(), keyword()) :: iodata()
  def attach(path, name, options \\ []) when is_binary(path) and is_list(options) do
    {if_not_exists, options} = Keyword.pop(options, :if_not_exists, false)

    [
      "ATTACH ",
      if_not_exists(if_not_exists: if_not_exists),
      QuackDB.SQL.literal!(path),
      " AS ",
      schema(name),
      attach_options(options)
    ]
  end

  @doc "Builds a `DETACH` statement. Supports `if_exists: true`."
  @spec detach(atom() | String.t(), keyword()) :: iodata()
  def detach(name, options \\ []) do
    options = Keyword.validate!(options, if_exists: false)
    ["DETACH ", if_exists(options), schema(name)]
  end

  defp attach_options([]), do: []

  defp attach_options(options) do
    options =
      Enum.map(options, fn {key, value} ->
        [attach_option_name(key), ?\s, attach_option_value(value)]
      end)

    [" (", Enum.intersperse(options, ", "), ")"]
  end

  defp attach_option_name(key) when is_atom(key) do
    name = Atom.to_string(key)

    unless QuackDB.Identifier.valid?(name) do
      raise ArgumentError, "invalid DuckDB attach option: #{inspect(key)}"
    end

    String.upcase(name)
  end

  defp attach_option_value(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value),
       do: attach_option_name(value) |> String.downcase()

  defp attach_option_value(value), do: QuackDB.SQL.literal!(value)

  @doc """
  Builds a DuckDB 2.0 `CREATE TRIGGER` statement that runs `statement`, a SQL
  statement such as an `INSERT` or `UPDATE`, when `event` changes `table`.

  Triggers are schema, so they usually live in an Ecto migration. The body is
  DuckDB SQL because it reads the transition table:

      alias QuackDB.DDL

      def up do
        execute DDL.create_trigger(:events_count, :events,
          "UPDATE event_stats SET total = total + (SELECT count(*) FROM inserted)",
          event: :insert,
          referencing: [new_table: :inserted]
        )
      end

      def down, do: execute(DDL.drop_trigger(:events_count, :events))

  Options:

    * `:event` (required) - `:insert`, `:delete`, `:update`, or
      `{:update, columns}` for `UPDATE OF columns`.
    * `:timing` - `:after` (default) or `:before`.
    * `:for_each` - `:statement` (default) or `:row`. Row triggers refer to the
      changed row as `NEW` and `OLD`.
    * `:referencing` - transition tables as `[old_table: alias, new_table: alias]`.
    * `:or_replace` and `:if_not_exists` - booleans.

  DuckDB 2.0 does not run `BEFORE ... FOR EACH ROW` or `UPDATE ... FOR EACH ROW`
  triggers yet, and a table cannot mix row and statement triggers; the server
  rejects those.
  """
  @spec create_trigger(
          QuackDB.SQL.Fragment.identifier_name(),
          QuackDB.SQL.Fragment.table(),
          iodata(),
          keyword()
        ) ::
          iodata()
  def create_trigger(name, table, statement, options) do
    options =
      Keyword.validate!(options, [
        :event,
        timing: :after,
        for_each: :statement,
        referencing: [],
        or_replace: false,
        if_not_exists: false
      ])

    [
      "CREATE ",
      if(options[:or_replace], do: "OR REPLACE ", else: []),
      "TRIGGER ",
      if_not_exists(options),
      alias_name(name),
      trigger_timing(options[:timing]),
      trigger_event(options[:event]),
      " ON ",
      table(table),
      trigger_referencing(options[:referencing]),
      trigger_for_each(options[:for_each]),
      " ",
      statement
    ]
  end

  @doc "Builds a `DROP TRIGGER name ON table` statement, optionally with `if_exists: true`."
  @spec drop_trigger(
          QuackDB.SQL.Fragment.identifier_name(),
          QuackDB.SQL.Fragment.table(),
          keyword()
        ) ::
          iodata()
  def drop_trigger(name, table, options \\ []) do
    options = Keyword.validate!(options, if_exists: false)
    ["DROP TRIGGER ", if_exists(options), alias_name(name), " ON ", table(table)]
  end

  defp trigger_timing(:after), do: " AFTER "
  defp trigger_timing(:before), do: " BEFORE "

  defp trigger_timing(other),
    do: raise(ArgumentError, "invalid trigger :timing: #{inspect(other)}")

  defp trigger_event(:insert), do: "INSERT"
  defp trigger_event(:delete), do: "DELETE"
  defp trigger_event(:update), do: "UPDATE"
  defp trigger_event({:update, [_ | _] = columns}), do: ["UPDATE OF ", column_list(columns)]
  defp trigger_event(other), do: raise(ArgumentError, "invalid trigger :event: #{inspect(other)}")

  defp trigger_referencing([]), do: []

  defp trigger_referencing(tables) when is_list(tables) do
    [" REFERENCING" | Enum.map(tables, &trigger_transition_table/1)]
  end

  defp trigger_transition_table({:old_table, name}), do: [" OLD TABLE AS ", alias_name(name)]
  defp trigger_transition_table({:new_table, name}), do: [" NEW TABLE AS ", alias_name(name)]

  defp trigger_transition_table(other),
    do: raise(ArgumentError, "invalid trigger :referencing entry: #{inspect(other)}")

  defp trigger_for_each(:statement), do: " FOR EACH STATEMENT"
  defp trigger_for_each(:row), do: " FOR EACH ROW"

  defp trigger_for_each(other),
    do: raise(ArgumentError, "invalid trigger :for_each: #{inspect(other)}")

  defp sequence_option({:start, value}) when is_integer(value),
    do: [" START ", Integer.to_string(value)]

  defp sequence_option({:increment, value}) when is_integer(value) and value != 0,
    do: [" INCREMENT ", Integer.to_string(value)]

  defp sequence_option({key, value})
       when key in [:if_exists, :if_not_exists] and is_boolean(value),
       do: []

  defp sequence_option(option),
    do: raise(ArgumentError, "invalid sequence option: #{inspect(option)}")

  defp table_query(%{__struct__: Ecto.Query} = query) do
    assert_unparameterized_query!(query)
    apply(Ecto.Adapters.QuackDB.Query, :all_literal, [query])
  end

  defp table_query(query), do: query

  defp assert_unparameterized_query!(query) do
    if parameterized_query?(query) do
      raise ArgumentError,
            "QuackDB.DDL.create_table/2 with :as does not support parameterized Ecto queries; use literal query expressions or materialize with Repo.all/query first"
    end
  end

  defp parameterized_query?(%{__struct__: Ecto.Query} = query) do
    query
    |> Map.take([
      :wheres,
      :havings,
      :order_bys,
      :group_bys,
      :combinations,
      :select,
      :joins,
      :limit,
      :offset
    ])
    |> parameterized_query?()
  end

  defp parameterized_query?(%{params: [_ | _]}), do: true

  defp parameterized_query?(%struct{} = value) when is_atom(struct) do
    value
    |> Map.from_struct()
    |> parameterized_query?()
  end

  defp parameterized_query?(value) when is_map(value) do
    Enum.any?(value, fn {_key, field} -> parameterized_query?(field) end)
  end

  defp parameterized_query?(value) when is_list(value),
    do: Enum.any?(value, &parameterized_query?/1)

  defp parameterized_query?(_value), do: false

  defp schema_columns(schema) do
    Enum.map(schema.__schema__(:fields), fn field ->
      {field, schema_field_type!(schema, field)}
    end)
  end

  defp schema_field_type!(schema, field) do
    schema.__schema__(:type, field)
    |> then(&apply(QuackDB.Ecto.Type, :column_type!, [&1, :schema]))
  rescue
    error in ArgumentError ->
      raise ArgumentError,
            "unsupported Ecto schema type for #{inspect(schema)}.#{field}: #{Exception.message(error)}"
  end

  defp assert_create_options!(options) do
    if Keyword.get(options, :or_replace, false) and Keyword.get(options, :if_not_exists, false) do
      raise ArgumentError,
            "create_table options :or_replace and :if_not_exists cannot be used together"
    end
  end

  defp or_replace(options) do
    if Keyword.get(options, :or_replace, false), do: "OR REPLACE ", else: []
  end

  defp temporary(options) do
    if Keyword.get(options, :temporary, false), do: "TEMP ", else: []
  end

  defp if_not_exists(options) do
    if Keyword.get(options, :if_not_exists, false), do: "IF NOT EXISTS ", else: []
  end

  defp if_exists(options) do
    if Keyword.get(options, :if_exists, false), do: "IF EXISTS ", else: []
  end

  defp table_options!(options) do
    {checks, options} = Enum.split_with(options, &is_struct(&1, Check))
    options = Keyword.validate!(options, [:temporary, :if_not_exists, :or_replace, :as])
    {options, checks}
  end

  defp columns([]), do: raise(ArgumentError, "expected at least one column")

  defp columns(columns) do
    columns
    |> Enum.map(&ddl_column/1)
    |> Enum.intersperse(", ")
  end

  defp ddl_column({name, type}) do
    [column(name), " ", QuackDB.Type.to_sql(type)]
  end

  defp ddl_column({name, type, options}) when is_list(options) do
    [
      column(name),
      " ",
      QuackDB.Type.to_sql(type),
      column_options(options)
    ]
  end

  defp ddl_column(other) do
    raise ArgumentError, "expected column as {name, type}, got: #{inspect(other)}"
  end

  defp column_options(options) do
    [
      nullable(options),
      primary_key(options),
      default(options)
    ]
  end

  defp nullable(options) do
    if Keyword.get(options, :null, true), do: [], else: " NOT NULL"
  end

  defp primary_key(options) do
    if Keyword.get(options, :primary_key, false), do: " PRIMARY KEY", else: []
  end

  defp default(options) do
    case Keyword.fetch(options, :default) do
      {:ok, value} -> [" DEFAULT ", literal!(value)]
      :error -> []
    end
  end

  defp literal!(value) do
    case QuackDB.SQL.literal(value) do
      {:ok, literal} -> literal
      {:error, %QuackDB.Error{} = error} -> raise error
    end
  end
end
