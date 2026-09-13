defmodule QuackDB.ErrorTest do
  use ExUnit.Case, async: true

  alias QuackDB.Error

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

    for message <- [json, "Failed to append: " <> json] do
      error = Error.server(message)
      assert error.message == message
      assert error.code == :server_error
      refute error.retriable?
      assert error.metadata == %{exception_type: "Constraint", exception_message: "Duplicate key"}
    end
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
          "Failed to append: {",
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

  test "keeps other server errors non-retriable" do
    assert %Error{code: :server_error, retriable?: false, source: :server} =
             Error.server("Catalog Error: table does not exist")
  end
end
