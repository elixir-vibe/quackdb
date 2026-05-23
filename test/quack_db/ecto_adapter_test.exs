defmodule QuackDB.EctoRepo do
  use Ecto.Repo,
    otp_app: :quackdb,
    adapter: Ecto.Adapters.QuackDB
end

defmodule QuackDB.EctoAdapterTest do
  use ExUnit.Case, async: false

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.PrepareRequest

  import Ecto.Query

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

    Application.put_env(:quackdb, QuackDB.EctoRepo,
      uri: "http://localhost:9494",
      token: "secret",
      transport: transport(prepare: [chunk]),
      pool_size: 1,
      log: false
    )

    start_supervised!(QuackDB.EctoRepo)

    assert {:ok, result} = QuackDB.EctoRepo.query("SELECT 1 AS n")
    assert result.columns == ["n"]
    assert result.rows == [[1]]
    assert result.num_rows == 1
    assert result.command == :select
  end

  test "Repo.query/3 returns affected row counts for commands" do
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([2])

    Application.put_env(:quackdb, QuackDB.EctoRepo,
      uri: "http://localhost:9494",
      token: "secret",
      transport: transport(prepare: [chunk], names: ["Count"]),
      pool_size: 1,
      log: false
    )

    start_supervised!(QuackDB.EctoRepo)

    assert {:ok, result} = QuackDB.EctoRepo.query("INSERT INTO events VALUES (1), (2)")
    assert result.columns == nil
    assert result.rows == nil
    assert result.num_rows == 2
    assert result.command == :insert
    assert result.metadata[:duckdb_rows] == [[2]]
  end

  test "raises ArgumentError for non-list params like other Ecto SQL adapters" do
    assert_raise ArgumentError, ~r/expected params to be a list/, fn ->
      Ecto.Adapters.QuackDB.Connection.query(self(), "SELECT 1", %{bad: :params}, [])
    end
  end

  test "Repo.query/3 formats parameter lists as SQL literals" do
    parent = self()
    chunk = QuackDB.ProtocolFixtures.integer_chunk_wrapper([1])

    Application.put_env(:quackdb, QuackDB.EctoRepo,
      uri: "http://localhost:9494",
      token: "secret",
      transport: transport(parent: parent, prepare: [chunk]),
      pool_size: 1,
      log: false
    )

    start_supervised!(QuackDB.EctoRepo)

    assert {:ok, %{rows: [[1]]}} = QuackDB.EctoRepo.query("SELECT ? AS n", ["duck"])
    assert_received {:statement, "SELECT 'duck' AS n"}
  end

  test "generates basic read-only Ecto select SQL" do
    query =
      from(event in "events",
        where: event.id > 1 and event.name != "goose",
        order_by: [asc: event.id],
        limit: 10,
        offset: 2,
        select: %{id: event.id, name: event.name}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "id", q0."name" AS "name" FROM "events" AS q0 WHERE ((q0."id" > 1) AND (q0."name" <> 'goose')) ORDER BY q0."id" ASC LIMIT 10 OFFSET 2]
  end

  test "generates read-only Ecto SQL for aggregates and common predicates" do
    query =
      from(event in "events",
        where: like(event.name, "d%") and not is_nil(event.name),
        select: %{count: count(event.id)}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT COUNT(q0."id") AS "count" FROM "events" AS q0 WHERE ((q0."name" LIKE 'd%') AND (q0."name" IS NOT NULL))]
  end

  test "generates read-only Ecto SQL for fragments" do
    query = from(event in "events", select: %{upper_name: fragment("upper(?)", event.name)})

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT upper(q0."name") AS "upper_name" FROM "events" AS q0]
  end

  test "Repo.all/2 executes simple read-only Ecto queries" do
    parent = self()

    chunk =
      QuackDB.ProtocolFixtures.scalar_chunk_wrapper([
        {:integer, :int32, [1]},
        {:varchar, :varchar, ["duck"]}
      ])

    Application.put_env(:quackdb, QuackDB.EctoRepo,
      uri: "http://localhost:9494",
      token: "secret",
      transport: transport(parent: parent, prepare: [chunk], names: ["id", "name"]),
      pool_size: 1,
      log: false
    )

    start_supervised!(QuackDB.EctoRepo)

    query = from(event in "events", select: %{id: event.id, name: event.name})

    assert [%{id: 1, name: "duck"}] = QuackDB.EctoRepo.all(query)

    assert_received {:statement,
                     ~s(SELECT q0."id" AS "id", q0."name" AS "name" FROM "events" AS q0)}
  end

  test "generates Ecto SQL from DuckDB source helpers" do
    source = QuackDB.Source.csv("events.csv", header: true)

    query =
      from(event in source,
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "id", q0."name" AS "name" FROM read_csv('events.csv', header = TRUE) AS q0 WHERE (q0."id" > 1)]
  end

  test "generates Ecto SQL from source fragments" do
    query =
      from(event in fragment("read_csv(?)", ^"events.csv"),
        where: event.id > 1,
        select: %{id: event.id}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "id" FROM read_csv(?) AS q0 WHERE (q0."id" > 1)]
  end

  test "generates Ecto SQL from subquery sources" do
    inner_query = from(event in "events", where: event.id > 1, select: %{id: event.id})
    query = from(event in subquery(inner_query), select: %{id: event.id})

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" AS "id" FROM (SELECT q0."id" AS "id" FROM "events" AS q0 WHERE (q0."id" > 1)) AS q0]
  end

  test "generates Ecto SQL with CTEs" do
    cte_query =
      from(event in "events",
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    query =
      "recent"
      |> with_cte("recent", as: ^cte_query)
      |> select([event], %{id: event.id})

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[WITH "recent" AS (SELECT q0."id" AS "id", q0."name" AS "name" FROM "events" AS q0 WHERE (q0."id" > 1)) SELECT q0."id" AS "id" FROM "recent" AS q0]
  end

  test "generates Ecto SQL with window functions" do
    query =
      from(event in "events",
        windows: [by_kind: [partition_by: event.kind, order_by: [desc: event.id]]],
        select: %{
          row_number: over(row_number(), :by_kind),
          running_score: over(sum(event.score), :by_kind)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT ROW_NUMBER() OVER "by_kind" AS "row_number", SUM(q0."score") OVER "by_kind" AS "running_score" FROM "events" AS q0 WINDOW "by_kind" AS (PARTITION BY q0."kind" ORDER BY q0."id" DESC)]
  end

  test "generates aggregate FILTER expressions" do
    query =
      from(event in "events",
        select: %{duck_count: filter(count(event.id), event.kind == "duck")}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT COUNT(q0."id") FILTER (WHERE (q0."kind" = 'duck')) AS "duck_count" FROM "events" AS q0]
  end

  test "generates analytical Ecto SQL with joins groupings and having" do
    query =
      from(event in "events",
        join: category in "categories",
        on: event.category_id == category.id,
        group_by: [event.category_id, category.name],
        having: count(event.id) > 1,
        select: %{category: category.name, count: count(event.id)}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q1."name" AS "category", COUNT(q0."id") AS "count" FROM "events" AS q0 INNER JOIN "categories" AS q1 ON (q0."category_id" = q1."id") GROUP BY q0."category_id", q1."name" HAVING (COUNT(q0."id") > 1)]
  end

  test "generates distinct and richer predicate Ecto SQL" do
    query =
      from(event in "events",
        distinct: [asc: event.category_id],
        where: event.category_id in [1, 2, 3] and not (event.score < 10),
        select: %{category_id: event.category_id, adjusted_score: event.score + 5}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT DISTINCT ON (q0."category_id") q0."category_id" AS "category_id", (q0."score" + 5) AS "adjusted_score" FROM "events" AS q0 WHERE ((q0."category_id" IN (1, 2, 3)) AND (NOT (q0."score" < 10)))]
  end

  test "unsupported Ecto query features raise explicit errors" do
    other_query = from(other in "other", select: other.id)
    query = from(event in "events", union: ^other_query, select: event.id)

    assert_raise QuackDB.Error, ~r/Ecto combinations are not supported yet/, fn ->
      Ecto.Adapters.QuackDB.Connection.all(query)
    end
  end

  defp transport(options) do
    prepare_chunks = Keyword.fetch!(options, :prepare)
    names = Keyword.get(options, :names, ["n"])
    parent = Keyword.get(options, :parent)

    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}} ->
          if parent, do: send(parent, {:statement, statement})
          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: prepare_chunks, names: names)}
      end
    end
  end

  defp connection_response do
    IO.iodata_to_binary([
      Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
      <<1::little-16, 5, "1.5.0">>,
      <<2::little-16, 6, "darwin">>,
      <<3::little-16, 1>>,
      <<0xFFFF::little-16>>
    ])
  end
end
