defmodule QuackDB.ErrorTest do
  use ExUnit.Case, async: true

  alias QuackDB.Error

  test "classifies update conflicts as retriable transaction conflicts" do
    assert %Error{code: :transaction_conflict, retriable?: true, source: :server} =
             Error.server("Conflict on update!")

    assert %Error{code: :transaction_conflict, retriable?: true, source: :server} =
             Error.server("Transaction conflict: cannot update a table that has been altered!")
  end

  test "keeps other server errors non-retriable" do
    assert %Error{code: :server_error, retriable?: false, source: :server} =
             Error.server("Catalog Error: table does not exist")
  end
end
