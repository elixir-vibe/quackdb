defmodule QuackDB.ErrorTest do
  use ExUnit.Case, async: true

  alias QuackDB.Error
  alias QuackDB.Protocol.Message.ErrorResponse

  test "classifies update conflicts as retriable transaction conflicts" do
    assert %Error{code: :transaction_conflict, retriable?: true, source: :server} =
             Error.server("Conflict on update!")

    assert %Error{code: :transaction_conflict, retriable?: true, source: :server} =
             Error.server("Transaction conflict: cannot update a table that has been altered!")
  end

  test "decodes structured server errors without replacing their raw message" do
    json =
      JSON.encode!(%{
        "exception_type" => "Constraint",
        "exception_message" => "Duplicate key",
        "future_field" => 123
      })

    error = Error.server(json)
    assert error.message == json
    assert error.code == :server_error
    refute error.retriable?
    assert error.metadata == %{exception_type: "Constraint", exception_message: "Duplicate key"}
  end

  test "structured conflicts retain retry classification" do
    message =
      JSON.encode!(%{
        "exception_type" => "Transaction",
        "exception_message" => "Conflict on update!"
      })

    assert %Error{code: :transaction_conflict, retriable?: true, message: ^message} =
             Error.server(message)
  end

  test "malformed and unrelated JSON errors fall back to the original message" do
    for message <- [
          "plain error",
          "{",
          "[]",
          "null",
          "42",
          "{}",
          ~s({"exception_type":"Constraint"}),
          ~s({"exception_type":23,"exception_message":"bad"}),
          ~s({"exception_type":"Constraint","exception_message":null})
        ] do
      error = Error.server(message)
      assert error.message == message
      assert error.metadata == %{}
    end
  end

  test "unknown exception classes remain strings" do
    message =
      JSON.encode!(%{
        "exception_type" => "FutureClassNeverAnAtom",
        "exception_message" => "failure"
      })

    assert Error.server(message).metadata.exception_type == "FutureClassNeverAnAtom"
  end

  test "keeps DuckDB's exception type and transferable details from typed error responses" do
    error =
      Error.server(%ErrorResponse{
        message: "Table with name nope does not exist!",
        exception_type: "Catalog",
        extra_info: %{"name" => "nope", "type" => "Table"}
      })

    assert error.code == :server_error
    assert error.message == "Table with name nope does not exist!"
    assert Error.exception_type(error) == "Catalog"
    assert error.metadata.extra_info == %{"name" => "nope", "type" => "Table"}
    refute Map.has_key?(error.metadata, :must_invalidate)
    refute Error.disconnect?(error)
  end

  test "classifies interrupted queries as cancelled" do
    for type <- ["INTERRUPT", "Interrupt"] do
      error =
        Error.server(%ErrorResponse{
          message: "Interrupted: query was cancelled",
          exception_type: type
        })

      assert error.code == :query_cancelled
      refute error.retriable?
    end
  end

  test "invalidated and expired connections require a reconnect" do
    invalidated =
      Error.server(%ErrorResponse{message: "database is invalidated", must_invalidate: true})

    assert invalidated.code == :connection_invalidated
    assert invalidated.metadata.must_invalidate
    assert Error.disconnect?(invalidated)

    expired = Error.server("Connection heartbeat lease expired")
    assert expired.code == :connection_expired
    assert expired.retriable?
    assert Error.disconnect?(expired)
  end

  test "keeps other server errors non-retriable" do
    assert %Error{code: :server_error, retriable?: false, source: :server} =
             Error.server("Catalog Error: table does not exist")
  end
end
