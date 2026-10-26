defmodule QuackDB.Protocol.DuckDBFixturesTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.Protocol.DataChunk
  alias QuackDB.Protocol.Message.ConnectionResponse
  alias QuackDB.Protocol.Message.ErrorResponse
  alias QuackDB.Protocol.Message.FetchResponse
  alias QuackDB.Protocol.Message.PrepareResponse
  alias QuackDB.ProtocolCrossFixtures

  @fixture_dir Path.expand("../../fixtures/duckdb_2_0", __DIR__)

  test "connection response negotiates protocol version 3 with a heartbeat lease" do
    assert {:ok, {header, %ConnectionResponse{} = response}} = decode("connection_response.bin")

    assert header.connection_id != ""
    assert response.server_duckdb_version == "v2.0.0"
    assert response.quack_version == 3
    assert response.heartbeat_timeout_seconds == 60
  end

  test "error response carries the exception type and extra info" do
    assert {:ok, {_header, %ErrorResponse{} = response}} = decode("error_response_catalog.bin")

    assert response.exception_type == "Catalog"
    assert response.message =~ "missing_fixture_table does not exist"
    assert %{"name" => "missing_fixture_table", "type" => "Table"} = response.extra_info
    refute response.must_invalidate
  end

  test "prepare response decodes scalar chunks in the DuckDB 2.0 string layout" do
    assert {:ok, {_header, %PrepareResponse{} = response}} = decode("prepare_response_scalar.bin")

    assert response.query_uuid == 1
    refute response.needs_more_fetch
    assert rows(response) == decoded_rows(ProtocolCrossFixtures.scalar_chunk())
  end

  test "prepare response decodes nested chunks" do
    assert {:ok, {_header, %PrepareResponse{} = response}} = decode("prepare_response_nested.bin")

    assert rows(response) == decoded_rows(ProtocolCrossFixtures.nested_chunk())
  end

  test "fetch response decodes the chunk blob after the message body" do
    assert {:ok, {_header, %FetchResponse{} = response}} = decode("fetch_response_batch.bin")

    assert response.batch_index == 1
    assert response.total_batches == nil
    assert [%DataChunk{} | _] = response.results

    # DuckDB compresses the range column as a sequence vector.
    assert [[0, "0"], [1, "1"] | _] = Enum.flat_map(response.results, &DataChunk.rows/1)
  end

  test "terminal fetch response reports the batch count" do
    assert {:ok, {_header, %FetchResponse{results: [], total_batches: total}}} =
             decode("fetch_response_terminal.bin")

    assert total > 1
  end

  test "unshredded VARIANT values decode to Elixir terms" do
    assert {:ok, {_header, %PrepareResponse{} = response}} =
             decode("prepare_response_variant.bin")

    assert [[42], ["duck"], [nil], [object], [~D[2026-01-02]], [[]]] = rows(response)
    assert object == %{"a" => 1, "b" => [true, nil, Decimal.new("2.5")]}
  end

  test "shredded VARIANT columns merge typed fields with unshredded leftovers" do
    assert {:ok, {_header, %PrepareResponse{} = response}} =
             decode("prepare_response_shredded_variant.bin")

    assert :shredded in Enum.flat_map(response.results, fn chunk ->
             Enum.map(chunk.columns, & &1.vector_type)
           end)

    values = response |> rows() |> Map.new(fn [id, value] -> {id, value} end)

    assert map_size(values) == 2048
    assert values[0] == %{"n" => 0, "nested" => %{"k" => 0}}
    assert values[2044] == %{"n" => 2044, "nested" => %{"k" => 1}}
    assert values[5000] == %{"extra" => "left over", "n" => 1}
    assert values[5001] == 7
    assert values[5002] == nil
  end

  defp rows(%PrepareResponse{results: chunks, result_names: names}),
    do: Enum.flat_map(chunks, &DataChunk.rows(&1, names))

  defp decoded_rows(chunk) do
    {:ok, decoded, ""} =
      chunk |> DataChunk.encode() |> IO.iodata_to_binary() |> DataChunk.decode()

    DataChunk.rows(decoded)
  end

  defp decode(file), do: file |> read_fixture!() |> Codec.decode()

  defp read_fixture!(file), do: @fixture_dir |> Path.join(file) |> File.read!()
end
