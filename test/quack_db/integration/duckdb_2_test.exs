defmodule QuackDB.Integration.DuckDB2Test do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase
  import QuackDB.TestHelper, only: [unique_table: 1]

  @moduletag :integration

  @slow_query "SELECT count(*) FROM range(1000000000000) t(i) WHERE i % 7 = 3"

  test "connects with protocol version 3 and a negotiated heartbeat lease" do
    connection = start_connection!(heartbeat_timeout: 30)

    assert {:ok, %QuackDB.Result{rows: [["v2." <> _]]}} =
             QuackDB.query(connection, "SELECT version()")
  end

  test "cancels a running query from another process" do
    connection = start_connection!(pool_size: 1)
    connection_id = QuackDB.query!(connection, "SELECT 1").connection_id
    task = Task.async(fn -> QuackDB.query(connection, @slow_query, [], timeout: 60_000) end)

    Process.sleep(300)
    assert :ok = QuackDB.cancel(System.fetch_env!("QUACKDB_TEST_URI"), connection_id)

    assert {:error, %QuackDB.Error{code: :query_cancelled}} = Task.await(task, 60_000)
    assert {:ok, %QuackDB.Result{rows: [[2]]}} = QuackDB.query(connection, "SELECT 2")
  end

  # The server renews the lease only when a message arrives; the heartbeat
  # process keeps it alive while the connection itself is busy or checked out.
  test "a running query keeps its lease past the heartbeat timeout" do
    connection = start_connection!(pool_size: 1, heartbeat_timeout: 1, idle_interval: 60_000)
    connection_id = QuackDB.query!(connection, "SELECT 1").connection_id
    task = Task.async(fn -> QuackDB.query(connection, @slow_query, [], timeout: 60_000) end)

    # A cancel is a message on the same connection: an expired lease rejects it.
    Process.sleep(2_500)
    assert :ok = QuackDB.cancel(System.fetch_env!("QUACKDB_TEST_URI"), connection_id)

    assert {:error, %QuackDB.Error{code: :query_cancelled}} = Task.await(task, 60_000)

    assert {:ok, %QuackDB.Result{connection_id: ^connection_id}} =
             QuackDB.query(connection, "SELECT 2")
  end

  test "a checked-out connection keeps its lease while the caller works" do
    connection = start_connection!(pool_size: 1, heartbeat_timeout: 1, idle_interval: 60_000)

    assert {:ok, %QuackDB.Result{rows: [[2]]}} =
             DBConnection.run(connection, fn conn ->
               QuackDB.query!(conn, "SELECT 1")
               Process.sleep(2_200)
               QuackDB.query(conn, "SELECT 2")
             end)
  end

  test "idle pings keep a short heartbeat lease alive" do
    connection = start_connection!(pool_size: 1, heartbeat_timeout: 1, idle_interval: 200)
    connection_id = QuackDB.query!(connection, "SELECT 1").connection_id

    Process.sleep(2_200)

    assert {:ok, %QuackDB.Result{connection_id: ^connection_id}} =
             QuackDB.query(connection, "SELECT 2")
  end

  test "server errors carry DuckDB's exception type and details" do
    connection = start_connection!()

    assert {:error, %QuackDB.Error{} = error} =
             QuackDB.query(connection, "SELECT * FROM quackdb_missing_table")

    assert QuackDB.Error.exception_type(error) == "Catalog"
    assert error.message =~ "quackdb_missing_table does not exist"
    assert %{"name" => "quackdb_missing_table", "type" => "Table"} = error.metadata.extra_info
  end

  test "native appends stream more than one vector and honor ON CONFLICT and RETURNING" do
    connection = start_connection!()
    table = unique_table("duckdb2_append")

    QuackDB.query!(
      connection,
      "CREATE TEMP TABLE #{table} (id INTEGER PRIMARY KEY, name VARCHAR, tags VARCHAR[])"
    )

    rows = for id <- 1..5_000, do: [id: id, name: "row #{id}", tags: ["a", "#{id}"]]

    assert {:ok, %QuackDB.Result{num_rows: 5_000}} =
             QuackDB.insert_rows(connection, table, rows, batch_size: 3_000)

    assert {:ok, %QuackDB.Result{rows: [[5_000, 12_502_500, ["a", "1"]]]}} =
             QuackDB.query(connection, "SELECT count(*), sum(id), min(tags) FROM #{table}")

    assert {:ok, %QuackDB.Result{columns: ["id", "name"], rows: [[9_001, "new"]], num_rows: 1}} =
             QuackDB.insert_rows(
               connection,
               table,
               [[id: 1, name: "duplicate", tags: nil], [id: 9_001, name: "new", tags: nil]],
               columns: [id: :integer, name: :varchar, tags: {:list, :varchar}],
               on_conflict: :nothing,
               returning: [:id, :name]
             )
  end

  test "appends fill column defaults and keep mixed VARIANT values apart" do
    connection = start_connection!(pool_size: 1)
    table = unique_table("duckdb2_append_defaults")
    sequence = "#{table}_ids"

    QuackDB.query!(connection, "CREATE TEMP SEQUENCE #{sequence} START 100")

    QuackDB.query!(connection, """
    CREATE TEMP TABLE #{table} (
      id BIGINT DEFAULT nextval('#{sequence}'),
      created DATE DEFAULT DATE '2026-01-01',
      payload VARIANT
    )
    """)

    assert {:ok, %QuackDB.Result{rows: [[100], [101], [102], [103]]}} =
             QuackDB.insert_rows(
               connection,
               table,
               [[payload: %{x: 1}], [payload: [1, 2]], [payload: "duck"], [payload: nil]],
               columns: [payload: :variant],
               returning: [:id]
             )

    assert %QuackDB.Result{rows: rows} =
             QuackDB.query!(
               connection,
               "SELECT created, payload, variant_type(payload) FROM #{table} ORDER BY id"
             )

    assert rows == [
             [~D[2026-01-01], %{"x" => 1}, "OBJECT"],
             [~D[2026-01-01], [1, 2], "ARRAY"],
             [~D[2026-01-01], "duck", "VARCHAR"],
             [~D[2026-01-01], nil, nil]
           ]
  end

  test "appends inside a transaction roll back with it" do
    connection = start_connection!(pool_size: 1)
    table = unique_table("duckdb2_append_tx")
    QuackDB.query!(connection, "CREATE TEMP TABLE #{table} (id INTEGER)")

    assert {:error, :rollback} =
             DBConnection.transaction(connection, fn conn ->
               QuackDB.insert_rows!(conn, table, [[id: 1], [id: 2]])
               DBConnection.rollback(conn, :rollback)
             end)

    assert %QuackDB.Result{rows: [[0]]} =
             QuackDB.query!(connection, "SELECT count(*) FROM #{table}")
  end

  test "decodes VARIANT, TUPLE, and TIMESTAMPTZ_NS values" do
    connection = start_connection!()

    assert %QuackDB.Result{rows: rows} =
             QuackDB.query!(connection, """
             SELECT v FROM (VALUES
               (42::VARIANT),
               ({'a': 1, 'b': [true::VARIANT, NULL, 'x'::VARIANT]}::VARIANT),
               (NULL::VARIANT)
             ) t(v)
             """)

    assert rows == [[42], [%{"a" => 1, "b" => [true, nil, "x"]}], [nil]]

    assert %QuackDB.Result{rows: [[{1, "a"}]]} = QuackDB.query!(connection, "SELECT (1, 'a')")

    assert %QuackDB.Result{rows: [[%{}, 0], [nil, 1]]} =
             QuackDB.query!(
               connection,
               "SELECT CASE WHEN i = 0 THEN {} END, i FROM range(2) t(i) ORDER BY i"
             )

    assert %QuackDB.Result{
             rows: [[%QuackDB.NanosecondTimestamp{nanoseconds: 1_767_323_045_123_456_789}]]
           } =
             QuackDB.query!(
               connection,
               "SELECT TIMESTAMPTZ_NS '2026-01-02 03:04:05.123456789+00'"
             )
  end

  test "decodes shredded VARIANT columns from checkpointed storage" do
    connection = start_connection!(pool_size: 1)
    table = unique_table("duckdb2_shredded")
    QuackDB.query!(connection, "SET variant_minimum_shredding_size = 1")
    QuackDB.query!(connection, "CREATE TABLE #{table} (id INTEGER, v VARIANT)")

    try do
      QuackDB.query!(connection, """
      INSERT INTO #{table} VALUES (5000, {'n': 1, 'extra': 'left over'}::VARIANT), (5001, 7::VARIANT)
      """)

      QuackDB.query!(connection, """
      INSERT INTO #{table} SELECT i, {'n': i, 'nested': {'k': i % 3}}::VARIANT FROM range(4000) t(i)
      """)

      QuackDB.query!(connection, "CHECKPOINT")

      values =
        connection
        |> QuackDB.query!("SELECT id, v FROM #{table}")
        |> Map.fetch!(:rows)
        |> Map.new(fn [id, value] -> {id, value} end)

      assert map_size(values) == 4_002
      assert values[5000] == %{"extra" => "left over", "n" => 1}
      assert values[5001] == 7
      assert values[3_999] == %{"n" => 3_999, "nested" => %{"k" => 0}}
    after
      QuackDB.query!(connection, "DROP TABLE #{table}")
    end
  end

  test "statement triggers maintain aggregates from transition tables" do
    alias QuackDB.DDL

    connection = start_connection!(pool_size: 1)
    events = unique_table("duckdb2_trigger_events")
    stats = unique_table("duckdb2_trigger_stats")

    QuackDB.query!(connection, DDL.create_table(events, id: :integer, score: :integer))
    QuackDB.query!(connection, DDL.create_table(stats, n: :bigint, total: :bigint))
    QuackDB.query!(connection, "INSERT INTO #{stats} VALUES (0, 0)")

    try do
      QuackDB.query!(
        connection,
        DDL.create_trigger(
          :count_scores,
          events,
          "UPDATE #{stats} SET n = n + (SELECT count(*) FROM inserted), " <>
            "total = total + (SELECT coalesce(sum(score), 0) FROM inserted)",
          event: :insert,
          referencing: [new_table: :inserted]
        )
      )

      QuackDB.insert_rows!(connection, events, [[id: 1, score: 10], [id: 2, score: 3]])
      QuackDB.query!(connection, "INSERT INTO #{events} VALUES (3, 5)")

      assert %QuackDB.Result{rows: [[3, 18]]} =
               QuackDB.query!(connection, "SELECT * FROM #{stats}")

      QuackDB.query!(connection, DDL.drop_trigger(:count_scores, events))
      QuackDB.query!(connection, DDL.drop_trigger(:count_scores, events, if_exists: true))
    after
      QuackDB.query!(connection, DDL.drop_table(events, if_exists: true))
      QuackDB.query!(connection, DDL.drop_table(stats, if_exists: true))
    end
  end

  test "nested schemas, variables, and JSON mutation" do
    alias QuackDB.{DDL, SQL}

    connection = start_connection!(pool_size: 1)
    root = unique_table("duckdb2_finance")

    QuackDB.query!(connection, DDL.create_schema(root))
    QuackDB.query!(connection, DDL.create_schema([root, :reports]))
    QuackDB.query!(connection, DDL.create_table({[root, :reports], :ledger}, amount: :integer))
    QuackDB.insert_rows!(connection, :ledger, [[amount: 40]], schema: [root, :reports])
    QuackDB.query!(connection, "INSERT INTO #{root}.reports.ledger VALUES (2)")

    assert %QuackDB.Result{rows: [[42]]} =
             QuackDB.query!(connection, "SELECT sum(amount) FROM #{root}.reports.ledger")

    QuackDB.query!(connection, SQL.set_variable(:bonus, 8))

    assert %QuackDB.Result{rows: [[50]]} =
             QuackDB.query!(connection, "SELECT sum(amount) + $bonus FROM #{root}.reports.ledger")

    assert %QuackDB.Result{rows: [[json]]} =
             QuackDB.query!(
               connection,
               ~s|SELECT json_remove(json_set('{"a": 1, "b": 2}', '$.c', to_json('x')), '$.b')|
             )

    assert JSON.decode!(json) == %{"a" => 1, "c" => "x"}
    QuackDB.query!(connection, DDL.drop_schema(root, cascade: true))
  end

  test "VARIANT helpers run through an Ecto repo" do
    import Ecto.Query
    import QuackDB.Ecto.Variant

    start_repo!()
    table = unique_table("duckdb2_variant_events")
    QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table} (id INTEGER, payload VARIANT)")

    QuackDB.IntegrationRepo.query!("""
    INSERT INTO #{table} VALUES
      (1, {'kind': 'duck', 'tags': ['a', 'b']}::VARIANT),
      (2, 42::VARIANT)
    """)

    query =
      from(event in table,
        where: variant_type(event.payload) == "OBJECT",
        select: %{
          id: event.id,
          kind: variant_extract_string(event.payload, :kind),
          second_tag: variant_extract(event.payload, [:tags, 2]),
          keys: variant_keys(event.payload),
          tags: variant_array_length(event.payload, :tags),
          payload: event.payload
        }
      )

    assert [
             %{
               id: 1,
               kind: "duck",
               second_tag: "b",
               keys: keys,
               tags: 2,
               payload: %{"kind" => "duck", "tags" => ["a", "b"]}
             }
           ] = QuackDB.IntegrationRepo.all(query)

    assert Enum.sort(keys) == ["kind", "tags"]
  end

  test "copy_binaries releases the response behind kept strings" do
    sql = "SELECT repeat('x', 200) || i::VARCHAR AS s FROM range(5000) t(i)"
    shared = start_connection!(pool_size: 1)
    copied = start_connection!(pool_size: 1, copy_binaries: true)

    [[value] | _rows] = QuackDB.query!(shared, sql).rows
    assert :binary.referenced_byte_size(value) > 100 * byte_size(value)

    [[value] | _rows] = QuackDB.query!(shared, sql, [], copy_binaries: true).rows
    assert :binary.referenced_byte_size(value) == byte_size(value)

    [[value] | _rows] = QuackDB.query!(copied, sql).rows
    assert :binary.referenced_byte_size(value) == byte_size(value)
  end

  test "Repo queries accept copy_binaries" do
    import Ecto.Query

    start_repo!()
    table = unique_table("duckdb2_copy_events")

    QuackDB.IntegrationRepo.query!(
      "CREATE TEMP TABLE #{table} AS SELECT i AS id, repeat('x', 200) AS payload FROM range(5000) t(i)"
    )

    query = from(event in table, order_by: event.id, select: event.payload)

    [payload | _payloads] = QuackDB.IntegrationRepo.all(query)
    assert :binary.referenced_byte_size(payload) > 100 * byte_size(payload)

    [payload | _payloads] = QuackDB.IntegrationRepo.all(query, copy_binaries: true)
    assert :binary.referenced_byte_size(payload) == byte_size(payload)
  end

  test "GEOMETRY appends round-trip and CRS-typed columns decode" do
    connection = start_connection!(pool_size: 1)
    table = unique_table("duckdb2_shapes")
    QuackDB.query!(connection, "CREATE TEMP TABLE #{table} (id INTEGER, geom GEOMETRY)")
    [[wkb]] = QuackDB.query!(connection, "SELECT ST_AsWKB('POINT(1 2)'::GEOMETRY)").rows

    QuackDB.insert_rows!(connection, table, [[id: 1, geom: wkb], [id: 2, geom: nil]],
      columns: [id: :integer, geom: :geometry]
    )

    assert %QuackDB.Result{rows: [[1, "POINT (1 2)"], [2, nil]]} =
             QuackDB.query!(connection, "SELECT id, ST_AsText(geom) FROM #{table} ORDER BY id")

    assert %QuackDB.Result{rows: [[geometry]]} =
             QuackDB.query!(connection, "SELECT 'POINT(1 2)'::GEOMETRY('OGC:CRS84')")

    assert geometry == wkb
  end

  test "DECIMAL with zero scale decodes as Decimal" do
    connection = start_connection!()

    assert %QuackDB.Result{rows: [[%Decimal{} = whole, %Decimal{} = cents]]} =
             QuackDB.query!(connection, "SELECT 12::DECIMAL(18, 0), 12.5::DECIMAL(18, 2)")

    assert Decimal.equal?(whole, 12)
    assert Decimal.equal?(cents, Decimal.new("12.50"))
  end

  test "unsupported result types fail the query and keep the connection" do
    connection = start_connection!(pool_size: 1)

    assert {:error, %QuackDB.Error{code: :unsupported_type}} =
             QuackDB.query(connection, "SELECT 1::UNION(a INTEGER, b VARCHAR)")

    assert {:ok, %QuackDB.Result{rows: [[1]]}} = QuackDB.query(connection, "SELECT 1")
  end

  test "a failed handshake stops its HTTP connection" do
    uri = System.fetch_env!("QUACKDB_TEST_URI")
    {:links, links} = Process.info(self(), :links)

    assert {:error, %QuackDB.Error{}} =
             QuackDB.DBConnection.connect(uri: uri, token: "not-the-token")

    assert {:links, ^links} = Process.info(self(), :links)
  end

  test "Ecto CTEs and nested-schema appends under a prefix" do
    import Ecto.Query
    alias QuackDB.DDL

    start_repo!()
    root = unique_table("duckdb2_prefixed")
    prefix = "#{root}.reports"
    QuackDB.IntegrationRepo.query!(DDL.create_schema(root))
    QuackDB.IntegrationRepo.query!(DDL.create_schema([root, :reports]))

    QuackDB.IntegrationRepo.query!(
      DDL.create_table({[root, :reports], :ledger}, id: :integer, amount: :integer)
    )

    try do
      assert {2, _rows} =
               QuackDB.IntegrationRepo.insert_all(
                 "ledger",
                 [[id: 1, amount: 40], [id: 2, amount: 2]],
                 prefix: prefix,
                 insert_method: :append
               )

      large = from(entry in "ledger", where: entry.amount > 10, select: %{id: entry.id})

      query =
        "ledger"
        |> with_cte("large", as: ^large)
        |> join(:inner, [entry], big in "large", on: big.id == entry.id)
        |> select([entry], entry.amount)

      assert [40] = QuackDB.IntegrationRepo.all(query, prefix: prefix)
    after
      QuackDB.IntegrationRepo.query!(DDL.drop_schema(root, cascade: true))
    end
  end

  # The JSON and variable examples in guides/ecto.md.
  test "Ecto updates JSON in place and reads variables in one checkout" do
    import Ecto.Query
    import QuackDB.Ecto.Analytics, only: [json_remove: 2, json_set: 3, variable: 1]

    alias QuackDB.IntegrationRepo, as: Repo

    start_repo!()
    table = unique_table("duckdb2_json_events")
    Repo.query!("CREATE TEMP TABLE #{table} (id INTEGER, score INTEGER, payload JSON)")
    Repo.query!(~s|INSERT INTO #{table} VALUES (1, 5, '{"draft": true}'), (2, 20, '{}')|)

    assert {1, _rows} =
             from(event in table,
               where: event.id == ^1,
               update: [
                 set: [
                   payload: json_remove(json_set(event.payload, [:status], "archived"), [:draft])
                 ]
               ]
             )
             |> Repo.update_all([])

    assert [~s|{"status":"archived"}|] =
             Repo.all(from(event in table, where: event.id == 1, select: event.payload))

    assert [2] =
             Repo.checkout(fn ->
               Repo.query!(QuackDB.SQL.set_variable(:min_score, 10))

               Repo.all(
                 from(event in table,
                   where: event.score >= variable(:min_score),
                   select: event.id
                 )
               )
             end)
  end
end
