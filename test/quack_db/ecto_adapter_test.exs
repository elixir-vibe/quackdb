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

  test "schema query generation raises an explicit unsupported feature error" do
    assert_raise QuackDB.Error, ~r/Ecto schema queries are not supported yet/, fn ->
      Ecto.Adapters.QuackDB.Connection.all(%Ecto.Query{})
    end
  end

  defp transport(options) do
    prepare_chunks = Keyword.fetch!(options, :prepare)
    names = Keyword.get(options, :names, ["n"])

    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
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
