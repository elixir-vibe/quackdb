defmodule QuackDB.Integration.ErrorTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  @moduletag :integration

  test "decodes DuckDB JSON exceptions for queries and native appends" do
    connection = start_connection!()
    QuackDB.query!(connection, "CREATE TEMP TABLE error_payload (id INTEGER PRIMARY KEY)")
    QuackDB.query!(connection, "INSERT INTO error_payload VALUES (1)")
    QuackDB.query!(connection, "SET errors_as_json = true")

    assert {:error, query_error} =
             QuackDB.query(connection, "INSERT INTO error_payload VALUES (1)")

    assert query_error.metadata.exception_type == "Constraint"
    assert query_error.metadata.exception_message =~ "violates primary key constraint"

    assert JSON.decode!(query_error.message)["exception_message"] ==
             query_error.metadata.exception_message

    assert {:error, append_error} =
             QuackDB.insert_rows(connection, "error_payload", [%{"id" => 1}],
               columns: [{"id", :integer}]
             )

    assert append_error.metadata == query_error.metadata
    assert "Failed to append: " <> json = append_error.message
    assert JSON.decode!(json)["exception_type"] == "Constraint"
    refute append_error.retriable?
  end

  test "propagates server errors with query context" do
    connection = start_connection!()

    assert {:error, %QuackDB.Error{} = error} = QuackDB.query(connection, "SELEC broken")
    assert error.message =~ "syntax error"
    assert error.query == "SELEC broken"
    assert is_binary(error.connection_id)
  end
end
