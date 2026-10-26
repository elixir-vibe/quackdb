defmodule QuackDB.Integration.SnapshotTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase
  import QuackDB.Ecto.Snapshot

  alias QuackDB.{DDL, DuckLake, Extension, Source}
  alias QuackDB.IntegrationRepo, as: Repo

  @moduletag :integration
  @moduletag :tmp_dir

  defmodule Item do
    use Ecto.Schema

    @schema_prefix "snapshot_lake"
    schema "items" do
      field(:name, :string)
      field(:order_id, :integer)
    end
  end

  defmodule Order do
    use Ecto.Schema

    @schema_prefix "snapshot_lake"
    schema "orders" do
      field(:status, :string)
      has_many(:items, Item)
    end
  end

  describe "DuckLake" do
    setup %{tmp_dir: tmp_dir} do
      start_repo!()
      Repo.query!(Extension.install(:ducklake))
      Repo.query!(Extension.load(:ducklake))

      Repo.query!(
        DDL.attach("ducklake:" <> Path.join(tmp_dir, "meta.ducklake"), :snapshot_lake,
          data_path: Path.join(tmp_dir, "data")
        )
      )

      on_exit(fn -> detach(:snapshot_lake) end)

      Repo.query!(DDL.create_table({:snapshot_lake, :orders}, id: :bigint, status: :varchar))

      Repo.query!(
        DDL.create_table({:snapshot_lake, :items}, id: :bigint, order_id: :bigint, name: :varchar)
      )

      :ok
    end

    test "reads every table, preloads included, at a snapshot" do
      Repo.insert!(%Order{id: 1, status: "new"})
      Repo.insert!(%Item{id: 1, order_id: 1, name: "duck"})
      placed = current_snapshot()

      Repo.update_all(from(o in Order, where: o.id == 1), set: [status: "paid"])
      Repo.insert!(%Item{id: 2, order_id: 1, name: "lake"})
      Repo.delete_all(from(i in Item, where: i.id == 1))

      assert [%Order{status: "new", items: [%Item{name: "duck"}]}] =
               Order |> preload(:items) |> Repo.all(snapshot: [version: placed])

      order = Repo.get!(Order, 1, snapshot: [version: placed])

      assert %Order{status: "new", items: [%Item{name: "duck"}]} =
               Repo.preload(order, :items, snapshot: [version: placed])

      assert %Order{status: "paid", items: [%Item{name: "lake"}]} =
               Order |> Repo.get!(1) |> Repo.preload(:items)

      joined =
        from(o in Order, join: i in assoc(o, :items), select: {o.status, i.name})
        |> put_snapshot(version: placed)

      assert Repo.all(joined) == [{"new", "duck"}]
    end

    test "a DateTime reads the latest snapshot committed at or before it" do
      Repo.insert!(%Order{id: 1, status: "new"})

      [placed_at] =
        Repo.all(
          from(s in DuckLake.snapshots(:snapshot_lake),
            order_by: [desc: s.snapshot_id],
            limit: 1,
            select: s.snapshot_time
          )
        )

      Repo.update_all(Order, set: [status: "paid"])

      assert ["new"] = Repo.all(select(Order, [o], o.status), snapshot: placed_at)
      assert ["paid"] = Repo.all(select(Order, [o], o.status))

      assert {:error, %QuackDB.Error{message: message}} =
               safe_all(select(Order, [o], o.status), snapshot: ~U[2000-01-01 00:00:00Z])

      assert message =~ "No snapshot found"
      assert Repo.all(select(Order, [o], o.status)) == ["paid"]
    end

    test "changes list the rows each snapshot inserted, updated, and deleted" do
      Repo.insert!(%Order{id: 1, status: "new"})
      from = current_snapshot()
      Repo.update_all(Order, set: [status: "paid"])
      Repo.insert!(%Order{id: 2, status: "new"})
      Repo.delete_all(from(o in Order, where: o.id == 2))

      changes =
        Repo.all(
          from(
            c in DuckLake.changes(:snapshot_lake, Order, from: from + 1, to: current_snapshot()),
            order_by: [c.snapshot_id, c.change_type],
            select: {c.change_type, c.id, c.status}
          )
        )

      assert changes == [
               {"update_postimage", 1, "paid"},
               {"update_preimage", 1, "new"},
               {"insert", 2, "new"},
               {"delete", 2, "new"}
             ]

      # Both ends are included, for snapshot ids and for commit times.
      assert [{"insert", 1}] = change_types(from: from, to: from)

      [placed_at, last_at] =
        Repo.all(
          from(s in DuckLake.snapshots(:snapshot_lake),
            where: s.snapshot_id in [^from, ^current_snapshot()],
            order_by: s.snapshot_id,
            select: s.snapshot_time
          )
        )

      assert [{"insert", 1}] = change_types(from: placed_at, to: placed_at)
      assert length(change_types(from: placed_at, to: last_at)) == 5

      # An update deletes the row's old version, so deletions include it.
      assert [{1, "new"}, {2, "new"}] =
               Repo.all(
                 from(
                   i in DuckLake.deletions(:snapshot_lake, Order,
                     from: from + 1,
                     to: current_snapshot()
                   ),
                   order_by: i.id,
                   select: {i.id, i.status}
                 )
               )
    end

    test "commit messages tag the snapshot a transaction commits" do
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.insert!(%Order{id: 1, status: "new"})

          Repo.query!(
            DuckLake.set_commit_message(:snapshot_lake, "checkout",
              author: "replay",
              extra_info: %{visit: 42}
            )
          )
        end)

      assert [{"replay", "checkout", extra_info}] =
               Repo.all(
                 from(s in DuckLake.snapshots(:snapshot_lake),
                   where: s.commit_message == "checkout",
                   select: {s.author, s.commit_message, s.commit_extra_info}
                 )
               )

      assert JSON.decode!(extra_info) == %{"visit" => 42}
    end

    test "expired snapshots can no longer be read" do
      Repo.insert!(%Order{id: 1, status: "new"})
      placed = current_snapshot()
      Repo.update_all(Order, set: [status: "paid"])

      assert ["new"] = Repo.all(select(Order, [o], o.status), snapshot: [version: placed])
      Repo.query!(DuckLake.expire_snapshots(:snapshot_lake, versions: [placed]))

      assert {:error, %QuackDB.Error{}} =
               safe_all(select(Order, [o], o.status), snapshot: [version: placed])
    end
  end

  describe "Delta" do
    setup %{tmp_dir: tmp_dir} do
      start_repo!()
      Repo.query!(Extension.install(:delta))
      Repo.query!(Extension.load(:delta))

      path = Path.join(tmp_dir, "events")
      Repo.query!(DDL.attach(path, :snapshot_events, type: :delta))
      on_exit(fn -> detach(:snapshot_events) end)

      Repo.query!(
        DDL.create_table({:snapshot_events, :snapshot_events}, id: :bigint, name: :varchar)
      )

      Repo.insert_all("snapshot_events", [[id: 1, name: "a"]])
      Repo.insert_all("snapshot_events", [[id: 2, name: "b"]])

      %{path: path}
    end

    test "reads a table version, a timestamp, and delta_scan versions", %{path: path} do
      events = from(e in "snapshot_events", select: count())

      assert Repo.all(put_snapshot(events, version: 1)) == [1]
      assert Repo.all(events, snapshot: DateTime.utc_now()) == [2]
      assert Repo.all(events) == [2]

      assert Repo.all(from(e in Source.delta(path, version: 1), select: count())) == [1]

      Repo.query!(DDL.attach(path, :snapshot_events_v1, type: :delta, version: 1))
      on_exit(fn -> detach(:snapshot_events_v1) end)
      assert Repo.all(from(e in "snapshot_events_v1", select: count())) == [1]
    end

    test "joins a version with a plain table through put_snapshot/3" do
      Repo.query!(DDL.drop_table("snapshot_names", if_exists: true))
      Repo.query!(DDL.create_table("snapshot_names", id: :bigint, label: :varchar))
      Repo.insert_all("snapshot_names", [[id: 1, label: "first"], [id: 2, label: "second"]])

      query =
        from(e in "snapshot_events",
          as: :event,
          join: n in "snapshot_names",
          on: n.id == e.id,
          select: n.label
        )

      assert Repo.all(put_snapshot(query, :event, version: 1)) == ["first"]

      assert {:error, %QuackDB.Error{message: message}} =
               safe_all(put_snapshot(query, version: 1))

      assert message =~ "does not support time travel"
    end
  end

  defp change_types(range) do
    Repo.all(
      from(c in DuckLake.changes(:snapshot_lake, Order, range),
        order_by: [c.snapshot_id, c.change_type],
        select: {c.change_type, c.id}
      )
    )
  end

  defp current_snapshot do
    [id] = Repo.all(from(s in DuckLake.current_snapshot(:snapshot_lake), select: s.id))
    id
  end

  defp safe_all(query, opts \\ []) do
    {:ok, Repo.all(query, opts)}
  rescue
    error in QuackDB.Error -> {:error, error}
  end

  defp detach(name) do
    {uri, token} =
      {System.fetch_env!("QUACKDB_TEST_URI"), System.get_env("QUACKDB_TEST_TOKEN", "")}

    {:ok, conn} = QuackDB.start_link(uri: uri, token: token)
    QuackDB.query!(conn, DDL.detach(name, if_exists: true))
    GenServer.stop(conn)
  end
end
