if Code.ensure_loaded?(Explorer.DataFrame) do
  defmodule QuackDB.ExplorerTest do
    use ExUnit.Case, async: true

    import Ecto.Query

    alias Explorer.DataFrame
    alias QuackDB.Columns
    alias QuackDB.Protocol.Codec
    alias QuackDB.Protocol.Message.Header
    alias QuackDB.Result

    test "appends Explorer dataframes through native column append" do
      parent = self()

      transport = fn _uri, request, _options ->
        case request |> IO.iodata_to_binary() |> Codec.decode() do
          {:ok, {%Header{type: :connection_request}, _body}} ->
            response = [
              Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
              <<1::little-16, 5, "1.5.0">>,
              <<2::little-16, 6, "darwin">>,
              <<3::little-16, 1>>,
              <<0xFFFF::little-16>>
            ]

            {:ok, IO.iodata_to_binary(response)}

          {:ok, {%Header{type: :append_request}, append}} ->
            send(parent, {:append, append})

            response =
              Codec.encode(%QuackDB.Protocol.Message.SuccessResponse{}, connection_id: "conn-1")

            {:ok, IO.iodata_to_binary(response)}
        end
      end

      connection =
        start_supervised!({QuackDB, uri: "http://localhost:9494", transport: transport})

      dataframe = DataFrame.new(%{id: [1, 2], name: ["duck", "goose"]})

      assert {:ok, %QuackDB.Result{command: :insert, num_rows: 2}} =
               QuackDB.Explorer.insert_dataframe(connection, "events", dataframe)

      assert_received {:append, append}
      assert append.table_name == "events"
      assert append.append_chunk.row_count == 2
    end

    test "converts columnar results to Explorer dataframes" do
      columns = %Columns{
        names: ["id", "name"],
        original_names: ["id", "name"],
        columns: %{"id" => [1, 2], "name" => ["duck", "goose"]},
        num_rows: 2
      }

      assert {:ok, dataframe} = QuackDB.Explorer.from_columns(columns)
      assert DataFrame.names(dataframe) == ["id", "name"]
      assert DataFrame.shape(dataframe) == {2, 2}
      assert DataFrame.to_columns(dataframe) == %{"id" => [1, 2], "name" => ["duck", "goose"]}
    end

    test "converts row results to Explorer dataframes" do
      result = %Result{columns: ["id", "name"], rows: [[1, "duck"], [2, "goose"]], num_rows: 2}

      assert {:ok, dataframe} = QuackDB.Explorer.from_result(result)
      assert DataFrame.to_columns(dataframe) == %{"id" => [1, 2], "name" => ["duck", "goose"]}
    end

    test "queries Explorer dataframes" do
      transport = fn _uri, request, _options ->
        if match?(
             {:ok, {%Header{type: :connection_request}, _body}},
             Codec.decode(IO.iodata_to_binary(request))
           ) do
          response = [
            Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
            <<1::little-16, 5, "1.5.0">>,
            <<2::little-16, 6, "darwin">>,
            <<3::little-16, 1>>,
            <<0xFFFF::little-16>>
          ]

          {:ok, IO.iodata_to_binary(response)}
        else
          chunk =
            QuackDB.ProtocolFixtures.scalar_chunk_wrapper([
              {:integer, :int32, [1, 2]},
              {:varchar, :varchar, ["duck", "goose"]}
            ])

          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [chunk], names: ["id", "name"])}
        end
      end

      connection =
        start_supervised!({QuackDB, uri: "http://localhost:9494", transport: transport})

      assert {:ok, dataframe} =
               QuackDB.Explorer.dataframe(connection, "SELECT id, name FROM events")

      assert DataFrame.to_columns(dataframe) == %{"id" => [1, 2], "name" => ["duck", "goose"]}
    end

    test "queries Explorer dataframes from Ecto queries" do
      parent = self()

      transport = fn _uri, request, _options ->
        if match?(
             {:ok, {%Header{type: :connection_request}, _body}},
             Codec.decode(IO.iodata_to_binary(request))
           ) do
          response = [
            Codec.encode_header(%Header{type: :connection_response, connection_id: "conn-1"}),
            <<1::little-16, 5, "1.5.0">>,
            <<2::little-16, 6, "darwin">>,
            <<3::little-16, 1>>,
            <<0xFFFF::little-16>>
          ]

          {:ok, IO.iodata_to_binary(response)}
        else
          {:ok, {%Header{type: :prepare_request}, request}} =
            request |> IO.iodata_to_binary() |> Codec.decode()

          send(parent, {:statement, request.sql_query})

          chunk =
            QuackDB.ProtocolFixtures.scalar_chunk_wrapper([
              {:integer, :int32, [2]},
              {:varchar, :varchar, ["goose"]}
            ])

          {:ok, QuackDB.ProtocolFixtures.prepare_response(chunks: [chunk], names: ["id", "name"])}
        end
      end

      connection =
        start_supervised!({QuackDB, uri: "http://localhost:9494", transport: transport})

      query =
        from(event in "events",
          where: event.id > ^1,
          select: %{id: event.id, name: event.name}
        )

      assert {:ok, dataframe} = QuackDB.Explorer.dataframe(connection, query)
      assert DataFrame.to_columns(dataframe) == %{"id" => [2], "name" => ["goose"]}

      assert_received {:statement,
                       ~S[SELECT q0."id" AS "id", q0."name" AS "name" FROM "events" AS q0 WHERE (q0."id" > 1)]}
    end
  end
end
