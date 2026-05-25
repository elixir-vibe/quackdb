defmodule QuackDB.Integration.ErrorTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "propagates server errors with query context" do
    connection = start_connection!()

    assert {:error, %QuackDB.Error{} = error} = QuackDB.query(connection, "SELEC broken")
    assert error.message =~ "syntax error"
    assert error.query == "SELEC broken"
    assert is_binary(error.connection_id)
  end
end
