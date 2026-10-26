defmodule QuackDB.Ecto.Repo.QueryTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.TestTransports

  setup do
    previous = Application.get_env(:quackdb, QuackDB.EctoRepo)

    on_exit(fn ->
      if previous do
        Application.put_env(:quackdb, QuackDB.EctoRepo, previous)
      else
        Application.delete_env(:quackdb, QuackDB.EctoRepo)
      end
    end)

    :ok
  end

  test "Repo.query/3 executes raw SQL through QuackDB" do
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    put_repo_env(transport(prepare: [chunk]))
    start_supervised!(QuackDB.EctoRepo)

    assert {:ok, result} = QuackDB.EctoRepo.query("SELECT 1 AS n")
    assert result.columns == ["n"]
    assert result.rows == [[1]]
    assert result.num_rows == 1
    assert result.command == :select
  end

  test "Repo.query/3 returns affected row counts for commands" do
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([2])

    put_repo_env(transport(prepare: [chunk], names: ["Count"]))
    start_supervised!(QuackDB.EctoRepo)

    assert {:ok, result} = QuackDB.EctoRepo.query("INSERT INTO events VALUES (1), (2)")
    assert result.columns == nil
    assert result.rows == nil
    assert result.num_rows == 2
    assert result.command == :insert
    assert result.metadata[:duckdb_rows] == [[2]]
  end

  test "Repo.insert_all/3 executes generated SQL" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([2])

    put_repo_env(transport(parent: parent, prepare: [chunk], names: ["Count"]))
    start_supervised!(QuackDB.EctoRepo)

    assert {2, nil} =
             QuackDB.EctoRepo.insert_all("events", [
               [id: 1, name: "duck"],
               [id: 2, name: "goose"]
             ])

    assert_received {:statement,
                     ~s|INSERT INTO "events" ("id", "name") VALUES (1, 'duck'), (2, 'goose')|}
  end

  test "Repo.insert_all/3 preserves nil params as NULL values" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    put_repo_env(transport(parent: parent, prepare: [chunk], names: ["Count"]))
    start_supervised!(QuackDB.EctoRepo)

    assert {1, nil} =
             QuackDB.EctoRepo.insert_all("events", [
               [id: nil, name: "duck"]
             ])

    assert_received {:statement, ~s|INSERT INTO "events" ("id", "name") VALUES (NULL, 'duck')|}
  end

  test "Repo.insert_all/3 can use Quack append protocol explicitly" do
    parent = self()

    transport = append_transport(parent)

    put_repo_env(transport)
    start_supervised!(QuackDB.EctoRepo)

    assert {2, nil} =
             QuackDB.EctoRepo.insert_all(
               "events",
               [[id: 1, name: "duck"], [id: 2, name: "goose"]],
               insert_method: :append,
               chunk_every: 1
             )

    assert_receive {:send_data, %{chunks: [%{row_count: 1}]}}
    assert_receive {:send_data, %{chunks: [%{row_count: 1}]}}
  end

  test "Repo.insert_all/3 append supports explicit row append shape" do
    parent = self()

    transport = append_transport(parent)

    put_repo_env(transport)
    start_supervised!(QuackDB.EctoRepo)

    assert {1, nil} =
             QuackDB.EctoRepo.insert_all(
               "events",
               [[id: 1, name: "duck"]],
               insert_method: :append,
               append_shape: :rows
             )

    assert_receive {:send_data, %{chunks: [%{row_count: 1}]}}
  end

  test "Repo.insert_all/3 append rejects unsupported append shape" do
    put_repo_env(fn _uri, _request, _options -> flunk("transport should not be called") end)
    start_supervised!(QuackDB.EctoRepo)

    assert_raise QuackDB.Error, ~r/unsupported append_shape/, fn ->
      QuackDB.EctoRepo.insert_all("events", [[id: 1]],
        insert_method: :append,
        append_shape: :auto
      )
    end
  end

  test "Repo.insert_all/3 append streams RETURNING through a single INSERT" do
    parent = self()

    put_repo_env(append_transport(parent, returning_rows: [[id: 1], [id: 2]]))
    start_supervised!(QuackDB.EctoRepo)

    assert {2, [%{id: 1}, %{id: 2}]} =
             QuackDB.EctoRepo.insert_all(
               QuackDB.TestSchemas.RenamedEvent,
               [[id: 1, name: "duck"], [id: 2, name: "goose"]],
               insert_method: :append,
               returning: [:id]
             )

    assert_receive {:statement, insert_statement}
    assert insert_statement =~ ~s|INSERT INTO "renamed_events" ("id", "event_name") SELECT * FROM|
    assert insert_statement =~ ~s|)) RETURNING "id"|
    assert_receive {:send_data, %{chunks: [%{row_count: 2}]}}
    refute_received {:statement, "BEGIN"}
  end

  test "Repo.insert_all/3 append streams on_conflict nothing" do
    parent = self()

    put_repo_env(append_transport(parent, returning_rows: [[id: 2]]))
    start_supervised!(QuackDB.EctoRepo)

    assert {1, [%{id: 2}]} =
             QuackDB.EctoRepo.insert_all(
               QuackDB.TestSchemas.RenamedEvent,
               [[id: 1, name: "duck"], [id: 2, name: "goose"]],
               insert_method: :append,
               on_conflict: :nothing,
               conflict_target: [:id],
               returning: [:id]
             )

    assert_receive {:statement, insert_statement}
    assert insert_statement =~ ~s|)) ON CONFLICT ("id") DO NOTHING RETURNING "id"|
  end

  test "Repo.insert_all/3 append runs inside an existing transaction" do
    parent = self()

    put_repo_env(append_transport(parent, returning_rows: [[id: 1]]))
    start_supervised!(QuackDB.EctoRepo)

    assert {:ok, {1, [%{id: 1}]}} =
             QuackDB.EctoRepo.transaction(fn ->
               QuackDB.EctoRepo.insert_all(
                 QuackDB.TestSchemas.RenamedEvent,
                 [[id: 1, name: "duck"]],
                 insert_method: :append,
                 returning: [:id]
               )
             end)

    assert_receive {:statement, "BEGIN"}
    assert_receive {:statement, ~s|INSERT INTO "renamed_events"| <> _}
    assert_receive {:statement, "COMMIT"}
  end

  test "Repo.insert_all/3 append supports schemaless returning" do
    parent = self()

    put_repo_env(append_transport(parent, returning_rows: [[id: 1]]))
    start_supervised!(QuackDB.EctoRepo)

    assert {1, [%{id: 1}]} =
             QuackDB.EctoRepo.insert_all("events", [[id: 1]],
               insert_method: :append,
               returning: [:id]
             )
  end

  test "Repo.insert_all/3 append uses schema types for all-nil columns" do
    parent = self()

    transport = append_transport(parent)

    put_repo_env(transport)
    start_supervised!(QuackDB.EctoRepo)

    assert {1, nil} =
             QuackDB.EctoRepo.insert_all(
               QuackDB.TestSchemas.TypedEvent,
               [[id: nil, event_date: nil, occurred_at: nil, tags: nil]],
               insert_method: :append
             )

    assert_receive {:statement, "INSERT INTO " <> _}
    assert_receive {:send_data, %{chunks: [chunk]}}

    assert chunk.types |> Enum.map(& &1.name) |> Enum.sort() == [
             :date,
             :integer,
             :list,
             :timestamp
           ]
  end

  test "Repo.insert_all/3 append maps schema Ecto.Enum fields to dumped column types" do
    parent = self()

    transport = append_transport(parent)

    put_repo_env(transport)
    start_supervised!(QuackDB.EctoRepo)

    assert {1, nil} =
             QuackDB.EctoRepo.insert_all(
               QuackDB.TestSchemas.TypedEvent,
               [[id: 1, status: :queued, priority: :high]],
               insert_method: :append
             )

    assert_receive {:send_data, %{chunks: [chunk]}}
    assert chunk.types |> Enum.map(& &1.name) |> Enum.sort() == [:integer, :integer, :varchar]
  end

  test "Repo.insert_all/3 append names its columns for tuple sources" do
    parent = self()

    transport = append_transport(parent)

    put_repo_env(transport)
    start_supervised!(QuackDB.EctoRepo)

    assert {1, nil} =
             QuackDB.EctoRepo.insert_all(
               {"runtime_fragment_terms", QuackDB.TestSchemas.FragmentTerm},
               [%{fragment_id: 10, term_id: 2}],
               insert_method: :append
             )

    assert_receive {:statement, ~s|INSERT INTO "runtime_fragment_terms" (| <> rest}
    assert_receive {:send_data, %{chunks: [chunk]}}
    assert [:integer, :integer] = Enum.map(chunk.types, & &1.name)

    [columns, _select] = String.split(rest, ")", parts: 2)
    names = columns |> String.split(", ") |> Enum.map(&String.trim(&1, ~s|"|))
    values = %{"fragment_id" => 10, "term_id" => 2}
    assert [Enum.map(names, &Map.fetch!(values, &1))] == QuackDB.Protocol.DataChunk.rows(chunk)
  end

  test "Repo.insert_all/3 append encodes Ecto map fields as JSON strings" do
    parent = self()

    transport = append_transport(parent)

    put_repo_env(transport)
    start_supervised!(QuackDB.EctoRepo)

    assert {1, nil} =
             QuackDB.EctoRepo.insert_all(
               QuackDB.TestSchemas.MapEvent,
               [[id: 1, metadata: %{reach_call_node_id: 15}]],
               insert_method: :append
             )

    assert_receive {:send_data, %{chunks: [chunk]}}
    assert [:integer, :varchar] = Enum.map(chunk.types, & &1.name)
    assert [[1, metadata]] = QuackDB.Protocol.DataChunk.rows(chunk)
    assert {:ok, %{"reach_call_node_id" => 15}} = JSON.decode(metadata)
  end

  test "Repo.insert_all/3 append preserves explicit columns before schema inference" do
    parent = self()

    transport = append_transport(parent)

    put_repo_env(transport)
    start_supervised!(QuackDB.EctoRepo)

    assert {1, nil} =
             QuackDB.EctoRepo.insert_all(
               QuackDB.TestSchemas.TypedEvent,
               [[priority: nil]],
               insert_method: :append,
               columns: [priority: :varchar]
             )

    assert_receive {:statement, insert_statement}
    assert insert_statement =~ ~s|NULL::STRUCT("priority" VARCHAR)|
    assert_receive {:send_data, %{chunks: [chunk]}}
    assert Enum.map(chunk.types, & &1.name) == [:varchar]
  end

  test "QuackDB.insert_stream/4 can use the Ecto repo pool" do
    parent = self()

    transport = append_transport(parent)

    put_repo_env(transport)
    start_supervised!(QuackDB.EctoRepo)

    assert {:ok, %QuackDB.Result{num_rows: 2}} =
             QuackDB.insert_stream(
               QuackDB.EctoRepo,
               "events",
               [%{id: 1, name: "duck"}, %{id: 2, name: "goose"}],
               chunk_every: 2
             )

    assert_receive {:send_data, %{chunks: [%{row_count: 2}]}}
  end

  test "Repo.insert_all/3 uses schema field source names" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    put_repo_env(transport(parent: parent, prepare: [chunk], names: ["Count"]))
    start_supervised!(QuackDB.EctoRepo)

    assert {1, nil} =
             QuackDB.EctoRepo.insert_all(QuackDB.TestSchemas.RenamedEvent, [
               [id: 1, name: "duck"]
             ])

    assert_received {:statement,
                     ~s|INSERT INTO "renamed_events" ("id", "event_name") VALUES (1, 'duck')|}
  end

  test "Repo.insert_all/3 rejects quoted identifier characters" do
    put_repo_env(transport(prepare: []))
    start_supervised!(QuackDB.EctoRepo)

    assert_raise ArgumentError, ~r/bad literal\/field\/table name/, fn ->
      QuackDB.EctoRepo.insert_all(~s|bad"events|, [[id: 1]])
    end
  end

  test "Repo.insert_all/3 rejects unknown insert methods" do
    put_repo_env(transport(prepare: []))
    start_supervised!(QuackDB.EctoRepo)

    assert_raise QuackDB.Error, ~r/unsupported insert_method/, fn ->
      QuackDB.EctoRepo.insert_all("events", [[id: 1]], insert_method: :warp)
    end
  end

  test "Repo.insert_all/3 append method rejects upsert updates" do
    put_repo_env(transport(prepare: []))
    start_supervised!(QuackDB.EctoRepo)

    assert_raise QuackDB.Error, ~r/only supports on_conflict: :raise or :nothing/, fn ->
      QuackDB.EctoRepo.insert_all("events", [[id: 1, name: "duck"]],
        insert_method: :append,
        on_conflict: [set: [name: "duck"]],
        conflict_target: [:id]
      )
    end
  end

  test "Repo.insert_all/3 append method rejects insert queries" do
    put_repo_env(transport(prepare: []))
    start_supervised!(QuackDB.EctoRepo)

    query = from(event in "source_events", select: %{id: event.id})

    assert_raise QuackDB.Error, ~r/does not support insert_all from queries/, fn ->
      QuackDB.EctoRepo.insert_all("events", query, insert_method: :append)
    end
  end

  test "Repo.insert_all/3 append method validates chunk_every" do
    put_repo_env(transport(prepare: []))
    start_supervised!(QuackDB.EctoRepo)

    assert_raise QuackDB.Error, ~r/batch_size must be a positive integer/, fn ->
      QuackDB.EctoRepo.insert_all("events", [[id: 1]], insert_method: :append, chunk_every: 0)
    end
  end

  test "raises ArgumentError for non-list params like other Ecto SQL adapters" do
    assert_raise ArgumentError, ~r/expected params to be a list/, fn ->
      Ecto.Adapters.QuackDB.Connection.query(self(), "SELECT 1", %{bad: :params}, [])
    end
  end

  test "Repo.query/3 formats NUL-containing binary params as blobs" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    put_repo_env(transport(parent: parent, prepare: [chunk]))
    start_supervised!(QuackDB.EctoRepo)

    assert {:ok, %{rows: [[1]]}} = QuackDB.EctoRepo.query("SELECT ? AS payload", [<<3, 2, 1, 0>>])
    assert_received {:statement, "SELECT from_hex('03020100') AS payload"}
  end

  test "Repo.query/3 formats parameter lists as SQL literals" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    put_repo_env(transport(parent: parent, prepare: [chunk]))
    start_supervised!(QuackDB.EctoRepo)

    assert {:ok, %{rows: [[1]]}} = QuackDB.EctoRepo.query("SELECT ? AS n", ["duck"])
    assert_received {:statement, "SELECT 'duck' AS n"}
  end

  test "Repo.all/2 executes simple read-only Ecto queries" do
    parent = self()

    chunk =
      QuackDB.ProtocolFixtures.scalar_chunk_wrapper([
        {:integer, :int32, [1]},
        {:varchar, :varchar, ["duck"]}
      ])

    put_repo_env(transport(parent: parent, prepare: [chunk], names: ["id", "name"]))
    start_supervised!(QuackDB.EctoRepo)

    query = from(event in "events", select: %{id: event.id, name: event.name})

    assert [%{id: 1, name: "duck"}] = QuackDB.EctoRepo.all(query)

    assert_received {:statement,
                     ~s(SELECT q0."id" AS "id", q0."name" AS "name" FROM "events" AS q0)}
  end

  defp put_repo_env(transport) do
    Application.put_env(:quackdb, QuackDB.EctoRepo,
      uri: "http://localhost:9494",
      token: "secret",
      transport: transport,
      pool_size: 1,
      log: false
    )
  end
end
