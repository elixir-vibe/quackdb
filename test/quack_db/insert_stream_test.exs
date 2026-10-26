defmodule QuackDB.InsertStreamTest do
  use ExUnit.Case, async: false

  alias QuackDB.Protocol.Message.SendDataRequest
  alias QuackDB.TestTransports

  test "insert_stream appends enumerable rows in chunks" do
    start_supervised!(
      {QuackDB,
       uri: "http://localhost:9494",
       token: "secret",
       transport: TestTransports.append_transport(self()),
       name: __MODULE__}
    )

    rows = Stream.map(1..3, &%{id: &1})

    assert {:ok, %QuackDB.Result{num_rows: 3}} =
             QuackDB.insert_stream(__MODULE__, "events", rows, chunk_every: 2)

    assert_receive {:send_data, %SendDataRequest{batch_index: 1, chunks: [%{row_count: 2}]}}
    assert_receive {:send_data, %SendDataRequest{batch_index: 1, chunks: [%{row_count: 1}]}}
  end

  test "insert_table appends Table.Reader-compatible data" do
    start_supervised!(
      {QuackDB,
       uri: "http://localhost:9494",
       token: "secret",
       transport: TestTransports.append_transport(self()),
       name: __MODULE__.Table}
    )

    assert {:ok, _result} =
             QuackDB.insert_table(__MODULE__.Table, "events", %{
               id: [1, 2],
               name: ["duck", "goose"]
             })

    assert_receive {:send_data, %SendDataRequest{batch_index: 1, chunks: [%{row_count: 2}]}}
  end
end
