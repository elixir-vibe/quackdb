defmodule QuackDB.DBConnection.TransactionTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.Codec
  alias QuackDB.ProtocolFixtures
  alias QuackDB.Protocol.Message.ConnectionRequest
  alias QuackDB.Protocol.Message.Header
  alias QuackDB.Protocol.Message.PrepareRequest

  import QuackDB.TestTransports

  test "DBConnection transactions issue BEGIN and COMMIT" do
    parent = self()
    connection = start_supervised!({QuackDB, transport: transport(parent: parent, prepare: [])})

    assert {:ok, :done} =
             DBConnection.transaction(connection, fn transaction_connection ->
               assert DBConnection.status(transaction_connection) == :transaction
               :done
             end)

    assert_received {:statement, "BEGIN"}
    assert_received {:statement, "COMMIT"}
  end

  test "DBConnection rollback issues ROLLBACK and returns rollback reason" do
    parent = self()
    connection = start_supervised!({QuackDB, transport: transport(parent: parent, prepare: [])})

    assert {:error, :rolled_back} =
             DBConnection.transaction(connection, fn transaction_connection ->
               DBConnection.rollback(transaction_connection, :rolled_back)
             end)

    assert_received {:statement, "BEGIN"}
    assert_received {:statement, "ROLLBACK"}
    refute_received {:statement, "COMMIT"}
  end

  test "rollback after query errors returns connection to usable idle state" do
    parent = self()
    chunk = ProtocolFixtures.integer_chunk_wrapper([1])

    connection =
      start_supervised!({QuackDB, transport: transaction_error_transport(parent, chunk)})

    assert {:error, :rolled_back} =
             DBConnection.transaction(connection, fn transaction_connection ->
               assert {:error, %QuackDB.Error{message: "syntax error"}} =
                        QuackDB.query(transaction_connection, "SELECT broken")

               assert DBConnection.status(transaction_connection) == :error
               DBConnection.rollback(transaction_connection, :rolled_back)
             end)

    assert {:ok, %QuackDB.Result{rows: [[1]]}} = QuackDB.query(connection, "SELECT 1 AS n")

    assert_received {:statement, "BEGIN"}
    assert_received {:statement, "SELECT broken"}
    assert_received {:statement, "ROLLBACK"}
    assert_received {:statement, "SELECT 1 AS n"}
  end

  test "failed BEGIN raises the server error" do
    connection =
      start_supervised!({QuackDB, transport: failing_transaction_statement_transport("BEGIN")})

    assert_raise QuackDB.Error, ~r/BEGIN failed/, fn ->
      DBConnection.transaction(connection, fn _transaction_connection ->
        flunk("transaction function should not run when BEGIN fails")
      end)
    end
  end

  test "failed COMMIT raises the server error" do
    connection =
      start_supervised!({QuackDB, transport: failing_transaction_statement_transport("COMMIT")})

    assert_raise QuackDB.Error, ~r/COMMIT failed/, fn ->
      DBConnection.transaction(connection, fn _transaction_connection ->
        :done
      end)
    end
  end

  test "failed ROLLBACK raises the server error instead of returning the rollback reason" do
    connection =
      start_supervised!({QuackDB, transport: failing_transaction_statement_transport("ROLLBACK")})

    assert_raise QuackDB.Error, ~r/ROLLBACK failed/, fn ->
      DBConnection.transaction(connection, fn transaction_connection ->
        DBConnection.rollback(transaction_connection, :rolled_back)
      end)
    end
  end

  defp transaction_error_transport(parent, recovery_chunk) do
    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT broken"}}} ->
          send(parent, {:statement, "SELECT broken"})
          {:ok, ProtocolFixtures.error_response("syntax error")}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: "SELECT 1 AS n"}}} ->
          send(parent, {:statement, "SELECT 1 AS n"})
          {:ok, ProtocolFixtures.prepare_response(chunks: [recovery_chunk])}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: statement}}} ->
          send(parent, {:statement, statement})
          {:ok, ProtocolFixtures.prepare_response(chunks: [])}
      end
    end
  end

  defp failing_transaction_statement_transport(failed_statement) do
    fn _uri, request, _request_options ->
      request = IO.iodata_to_binary(request)

      case Codec.decode(request) do
        {:ok, {%Header{type: :connection_request}, %ConnectionRequest{}}} ->
          {:ok, connection_response()}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{sql_query: ^failed_statement}}} ->
          {:ok, ProtocolFixtures.error_response("#{failed_statement} failed")}

        {:ok, {%Header{type: :prepare_request}, %PrepareRequest{}}} ->
          {:ok, ProtocolFixtures.prepare_response(chunks: [])}
      end
    end
  end
end
