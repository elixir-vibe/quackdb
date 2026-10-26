defmodule QuackDB.DuckLake do
  @moduledoc """
  SQL builders for DuckLake catalogs: listing snapshots, reading the rows that
  changed between them, tagging commits, and expiring old snapshots.

  Every commit to a DuckLake catalog creates a snapshot, one numbering for all
  of its tables. Read tables at a snapshot with `QuackDB.Ecto.Snapshot`, or
  `AT (VERSION => ...)` in SQL. Attach a catalog with `QuackDB.DDL.attach/3`.

  The table function helpers return SQL fragments that work as Ecto sources
  and in raw SQL, like `QuackDB.Source`:

      alias QuackDB.DuckLake

      from snapshot in DuckLake.snapshots(:lake),
        where: snapshot.snapshot_time <= ^event_at,
        order_by: [desc: snapshot.snapshot_id],
        limit: 1,
        select: snapshot.snapshot_id

      QuackDB.query!(conn, ["SELECT * FROM ", DuckLake.changes(:lake, :orders, from: 2, to: 5)])

  `set_commit_message/3` and `expire_snapshots/2` build `CALL` statements.
  """

  alias QuackDB.SQL

  @type catalog :: atom() | String.t()
  @type table :: atom() | String.t() | {atom() | String.t(), atom() | String.t()} | module()
  @type snapshot :: non_neg_integer() | DateTime.t()

  @doc """
  Builds a `ducklake_snapshots(...)` fragment listing the catalog's snapshots,
  with `snapshot_id`, `snapshot_time`, `schema_version`, `changes`, `author`,
  `commit_message`, and `commit_extra_info` columns.
  """
  @spec snapshots(catalog()) :: String.t()
  def snapshots(catalog), do: table_function("ducklake_snapshots", [name(catalog)])

  @doc "Builds a `ducklake_current_snapshot(...)` fragment with the catalog's latest snapshot `id`."
  @spec current_snapshot(catalog()) :: String.t()
  def current_snapshot(catalog), do: table_function("ducklake_current_snapshot", [name(catalog)])

  @doc """
  Builds a `ducklake_table_changes(...)` fragment with the rows of `table`
  that changed in snapshots `:from` through `:to`, both included. Both are
  snapshot ids or `DateTime`s; `DateTime`s take the snapshots committed
  between them. Each row has the table's columns and `snapshot_id`, `rowid`,
  and `change_type`: `insert`, `delete`, `update_preimage`, or
  `update_postimage`.

  `table` is a table name in the `main` schema, a `{schema, table}` pair, or
  an Ecto schema. A schema's `@schema_prefix` may name the catalog, as
  `"lake"` or `"lake.sales"`, or the schema within it.
  """
  @spec changes(catalog(), table(), keyword(snapshot())) :: String.t()
  def changes(catalog, table, range),
    do: table_range("ducklake_table_changes", catalog, table, range)

  @doc "Like `changes/3`, but only the inserted rows, without change columns."
  @spec insertions(catalog(), table(), keyword(snapshot())) :: String.t()
  def insertions(catalog, table, range),
    do: table_range("ducklake_table_insertions", catalog, table, range)

  @doc """
  Like `changes/3`, but only the deleted rows, without change columns. An
  update deletes the row's old version, so it appears here too.
  """
  @spec deletions(catalog(), table(), keyword(snapshot())) :: String.t()
  def deletions(catalog, table, range),
    do: table_range("ducklake_table_deletions", catalog, table, range)

  @doc """
  Builds a `CALL ducklake_set_commit_message(...)` statement that tags the
  snapshot the current transaction commits. Run it inside the transaction,
  after its writes:

      Repo.transaction(fn ->
        Repo.insert!(order)
        Repo.query!(DuckLake.set_commit_message(:lake, "checkout", extra_info: %{visit: 42}))
      end)

  Supports `:author` and `:extra_info`, a string or a map stored as JSON.
  """
  @spec set_commit_message(catalog(), String.t(), keyword()) :: iodata()
  def set_commit_message(catalog, message, options \\ []) when is_binary(message) do
    options = Keyword.validate!(options, author: nil, extra_info: nil)

    call("ducklake_set_commit_message", [
      name(catalog),
      options[:author],
      message,
      {:extra_info, extra_info(options[:extra_info])}
    ])
  end

  @doc """
  Builds a `CALL ducklake_expire_snapshots(...)` statement. Expired snapshots
  can no longer be read; DuckLake keeps every snapshot until they expire.

      DuckLake.expire_snapshots(:lake, older_than: DateTime.add(DateTime.utc_now(), -30, :day))
      DuckLake.expire_snapshots(:lake, versions: [1, 2], dry_run: true)

  Requires `:older_than` or `:versions`.
  """
  @spec expire_snapshots(catalog(), keyword()) :: iodata()
  def expire_snapshots(catalog, options) do
    options = Keyword.validate!(options, [:older_than, :versions, dry_run: false])

    call("ducklake_expire_snapshots", [
      name(catalog),
      expire_selection(options),
      {:dry_run, options[:dry_run]}
    ])
  end

  defp expire_selection(options) do
    case {options[:older_than], options[:versions]} do
      {%DateTime{} = at, nil} ->
        {:older_than, at}

      {nil, [_ | _] = versions} ->
        {:versions, versions}

      _other ->
        raise ArgumentError,
              "expected :older_than as a DateTime or :versions as a non-empty list, " <>
                "got: #{inspect(options)}"
    end
  end

  defp table_range(function, catalog, table, range) do
    range = Keyword.validate!(range, [:from, :to])
    {schema, table} = schema_table(name(catalog), table)

    table_function(function, [
      name(catalog),
      schema,
      table,
      snapshot!(range[:from]),
      snapshot!(range[:to])
    ])
  end

  defp schema_table(_catalog, {schema, table}), do: {name(schema), name(table)}

  defp schema_table(catalog, table) when is_atom(table) do
    if function_exported?(table, :__schema__, 1),
      do: {prefix_schema(catalog, table.__schema__(:prefix)), table.__schema__(:source)},
      else: {"main", name(table)}
  end

  defp schema_table(_catalog, table) when is_binary(table), do: {"main", table}

  # An Ecto schema's prefix may name the catalog itself, as "lake" or
  # "lake.sales", since Ecto reaches DuckLake tables through it.
  defp prefix_schema(_catalog, nil), do: "main"

  defp prefix_schema(catalog, prefix) do
    case String.split(to_string(prefix), ".", parts: 2) do
      [^catalog] -> "main"
      [^catalog, schema] -> schema
      _other -> to_string(prefix)
    end
  end

  defp snapshot!(id) when is_integer(id) and id >= 0, do: id
  defp snapshot!(%DateTime{} = at), do: at

  defp snapshot!(other) do
    raise ArgumentError,
          "expected :from and :to as snapshot ids or DateTimes, got: #{inspect(other)}"
  end

  defp extra_info(nil), do: nil
  defp extra_info(info) when is_binary(info), do: info
  defp extra_info(info) when is_map(info), do: JSON.encode!(info)

  defp table_function(function, arguments),
    do: IO.iodata_to_binary([function, "(", arguments(arguments), ")"])

  defp call(function, arguments), do: ["CALL ", function, "(", arguments(arguments), ")"]

  defp arguments(arguments) do
    arguments
    |> Enum.reject(&match?({_name, nil}, &1))
    |> Enum.map(fn
      {name, value} -> [Atom.to_string(name), " => ", SQL.literal!(value)]
      value -> SQL.literal!(value)
    end)
    |> Enum.intersperse(", ")
  end

  defp name(name) when is_atom(name), do: Atom.to_string(name)
  defp name(name) when is_binary(name), do: name
end
