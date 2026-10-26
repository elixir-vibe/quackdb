if Code.ensure_loaded?(Ecto.Query) do
  defmodule QuackDB.Ecto.Snapshot do
    @moduledoc """
    Reads Delta, DuckLake, and Iceberg tables as they were at an earlier
    snapshot, through DuckDB's `AT (VERSION => ...)` and `AT (TIMESTAMP => ...)`
    clauses.

    A snapshot is a `DateTime`, which reads the latest snapshot committed at or
    before it, or `version: n`, a Delta table version or a DuckLake snapshot id:

        import QuackDB.Ecto.Snapshot

        Order
        |> join(:inner, [o], c in assoc(o, :customer))
        |> put_snapshot(~U[2026-10-20 14:03:11Z])
        |> Repo.all()

    `put_snapshot/2` applies to every table the query reads: its joins,
    including assoc joins, subqueries, and CTE bodies. CTE names, `values/2`,
    fragments, and `QuackDB.Source` helpers are left as they are. Plain DuckDB
    tables do not keep snapshots, so a query that also reads one fails with
    DuckDB's `Catalog type does not support time travel`; give the snapshot to
    the time-travelling binding alone with `put_snapshot/3`.

    ## Repo option

    To give a whole repo call a snapshot, preloads included, apply the
    `:snapshot` option in your repo's `c:Ecto.Repo.prepare_query/3`:

        defmodule MyApp.Repo do
          use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.QuackDB

          @impl true
          defdelegate prepare_query(operation, query, opts), to: QuackDB.Ecto.Snapshot
        end

        order = Repo.get!(Order, id, snapshot: event.at)
        Repo.preload(order, :items, snapshot: event.at)

    Ecto passes a call's options on to its preload queries, so one snapshot
    covers the records a call loads. Snapshots are read-only: the option
    raises for `update_all` and `delete_all`.
    """

    alias QuackDB.SQL

    @typedoc "A snapshot to read: a commit time or a version."
    @type t :: DateTime.t() | [version: non_neg_integer()] | [timestamp: DateTime.t()]

    @doc """
    Reads every table in the query at `snapshot`. A `nil` snapshot leaves the
    query unchanged.
    """
    @spec put_snapshot(Ecto.Queryable.t(), t() | nil) :: Ecto.Query.t()
    def put_snapshot(queryable, nil), do: Ecto.Queryable.to_query(queryable)

    def put_snapshot(queryable, snapshot) do
      query = Ecto.Queryable.to_query(queryable)
      tag = {__MODULE__, clause!(snapshot)}
      update_in(query.from.hints, fn hints -> [tag | Enum.reject(hints, &statement_tag?/1)] end)
    end

    @doc """
    Reads only the source bound to the named `binding` at `snapshot`, so the
    query can join tables that do not keep snapshots, or read two snapshots of
    one table. The snapshot overrides one given to the whole query.

        from(order in Order, as: :order, join: region in "regions", on: ...)
        |> put_snapshot(:order, version: 42)

    Assoc joins lose their hints in Ecto's planner, so the binding must come
    from `from` or a join on an explicit source.
    """
    @spec put_snapshot(Ecto.Queryable.t(), atom(), t() | nil) :: Ecto.Query.t()
    def put_snapshot(queryable, binding, nil) when is_atom(binding),
      do: Ecto.Queryable.to_query(queryable)

    def put_snapshot(queryable, binding, snapshot) when is_atom(binding) do
      query = Ecto.Queryable.to_query(queryable)
      clause = clause!(snapshot)

      case Map.fetch(query.aliases, binding) do
        {:ok, 0} ->
          update_in(query.from.hints, &put_at_hint(&1, clause))

        {:ok, position} ->
          update_in(
            query.joins,
            &List.update_at(&1, position - 1, fn join -> put_join(join, binding, clause) end)
          )

        :error ->
          raise ArgumentError, "unknown named binding #{inspect(binding)} in #{inspect(query)}"
      end
    end

    @doc """
    Applies a repo call's `:snapshot` option to its query. Delegate
    `c:Ecto.Repo.prepare_query/3` to it, or call it from your own.
    """
    @spec prepare_query(atom(), Ecto.Query.t(), keyword()) :: {Ecto.Query.t(), keyword()}
    def prepare_query(operation, query, opts) do
      case Keyword.get(opts, :snapshot) do
        nil ->
          {query, opts}

        snapshot when operation in [:all, :stream] ->
          {put_snapshot(query, snapshot), opts}

        _snapshot ->
          raise ArgumentError,
                "snapshots are read-only; :snapshot is not supported for #{operation}"
      end
    end

    # The adapter reads the {__MODULE__, clause} tag; see its snapshot_clause/2.
    defp statement_tag?({__MODULE__, _clause}), do: true
    defp statement_tag?(_hint), do: false

    defp put_at_hint(hints, clause), do: [clause | Enum.reject(hints, &at_hint?/1)]

    defp at_hint?("AT " <> _clause), do: true
    defp at_hint?(_hint), do: false

    defp put_join(%{assoc: {_owner, assoc}}, binding, _clause) do
      raise ArgumentError,
            "cannot put a snapshot on binding #{inspect(binding)}, an assoc join to " <>
              "#{inspect(assoc)}; join its schema explicitly, or use put_snapshot/2"
    end

    defp put_join(join, _binding, clause), do: %{join | hints: put_at_hint(join.hints, clause)}

    defp clause!(%DateTime{} = timestamp), do: clause!(timestamp: timestamp)

    defp clause!(version: version) when is_integer(version) and version >= 0,
      do: "AT (VERSION => #{version})"

    defp clause!(timestamp: %DateTime{} = timestamp),
      do: IO.iodata_to_binary(["AT (TIMESTAMP => ", SQL.literal!(timestamp), ")"])

    defp clause!(snapshot) do
      raise ArgumentError,
            "expected a snapshot as a DateTime, version: non_neg_integer, or " <>
              "timestamp: DateTime, got: #{inspect(snapshot)}"
    end
  end
end
