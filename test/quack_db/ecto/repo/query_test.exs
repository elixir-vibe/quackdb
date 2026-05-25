defmodule QuackDB.Ecto.Repo.QueryTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.TestTransports

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.Message.AppendRequest
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.SuccessResponse

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

  test "Repo.insert_all/3 can use Quack append protocol explicitly" do
    parent = self()

    transport = fn _uri, request, _options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :append_request}, %AppendRequest{} = append}} ->
          send(parent, {:append, append})
          {:ok, IO.iodata_to_binary(Codec.encode(%SuccessResponse{}))}
      end
    end

    put_repo_env(transport)
    start_supervised!(QuackDB.EctoRepo)

    assert {2, nil} =
             QuackDB.EctoRepo.insert_all(
               "events",
               [[id: 1, name: "duck"], [id: 2, name: "goose"]],
               insert_method: :append,
               chunk_every: 1
             )

    assert_receive {:append, %{table_name: "events", append_chunk: %{row_count: 1}}}
    assert_receive {:append, %{table_name: "events", append_chunk: %{row_count: 1}}}
  end

  test "raises ArgumentError for non-list params like other Ecto SQL adapters" do
    assert_raise ArgumentError, ~r/expected params to be a list/, fn ->
      Ecto.Adapters.QuackDB.Connection.query(self(), "SELECT 1", %{bad: :params}, [])
    end
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
