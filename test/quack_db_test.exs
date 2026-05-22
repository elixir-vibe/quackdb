defmodule QuackDBTest do
  use ExUnit.Case, async: true

  test "exposes protocol message type ids" do
    assert QuackDB.Protocol.message_type(:connection_request) == 1
    assert QuackDB.Protocol.message_type(:error_response) == 100
  end

  test "returns an explicit not implemented error for queries" do
    connection = start_supervised!({QuackDB.Connection, uri: "http://localhost:9494"})

    assert {:error, %QuackDB.Error{code: :not_implemented}} =
             QuackDB.query(connection, "SELECT 1")
  end
end
