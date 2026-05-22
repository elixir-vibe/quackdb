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

  test "unsupported Ecto query features raise explicit errors" do
    query = from(event in "events", join: other in "other", on: true, select: event.id)

    assert_raise QuackDB.Error, ~r/Ecto joins are not supported yet/, fn ->
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
