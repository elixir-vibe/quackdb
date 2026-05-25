defmodule QuackDB.DBConnection.ErrorTest do
  use ExUnit.Case, async: true

  import QuackDB.TestTransports

  test "attaches query and connection context to server errors" do
    connection = start_supervised!({QuackDB, transport: transport_error("syntax error")})

    assert {:error, %QuackDB.Error{} = error} = QuackDB.query(connection, "SELECT")
    assert error.message == "syntax error"
    assert error.query == "SELECT"
    assert error.connection_id == "conn-1"
    assert Exception.message(error) =~ "query: SELECT"
  end
end
